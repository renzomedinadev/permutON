-- Ejecutar una vez después de migration-08.
-- Calificaciones entre las dos partes de una permuta concretada.
-- Al final se programa una segunda tarea automática (Cron).
begin;

create table public.reviews (
 id uuid primary key default gen_random_uuid(),
 offer_id uuid not null references public.offers(id) on delete cascade,
 reviewer_id uuid not null,
 reviewed_id uuid not null,
 rating smallint not null check (rating between 1 and 5),
 comment text check (comment is null or char_length(comment) <= 500),
 created_at timestamptz not null default now(),
 -- Se completa cuando califican los dos o a los 14 días de concretada la permuta.
 published_at timestamptz,
 constraint reviews_reviewer_id_fkey foreign key (reviewer_id) references public.profiles(id) on delete cascade,
 constraint reviews_reviewed_id_fkey foreign key (reviewed_id) references public.profiles(id) on delete cascade,
 constraint reviews_one_per_trade unique (offer_id, reviewer_id),
 constraint reviews_not_self check (reviewer_id <> reviewed_id)
);
create index reviews_reviewed_idx on public.reviews (reviewed_id, published_at desc) where published_at is not null;
alter table public.reviews enable row level security;
-- Publicadas: visibles para todos. Sin publicar: solo las ve quien las escribió.
create policy "read published or own reviews" on public.reviews for select to anon, authenticated
 using (published_at is not null or reviewer_id = (select auth.uid()));
revoke all on public.reviews from anon, authenticated;
grant select on public.reviews to anon, authenticated;

alter table public.offers add column review_reminders smallint not null default 0;

-- Momento en que se concretó: la última de las dos confirmaciones.
create or replace function public.trade_completed_at(o public.offers)
returns timestamptz language sql stable set search_path = '' as $$
 select coalesce(greatest(o.owner_responded_at, o.sender_responded_at), o.accepted_at, o.updated_at);
$$;

-- Al concretarse, pedir la calificación a las dos partes.
create or replace function public.request_reviews()
returns trigger language plpgsql security definer set search_path = '' as $$
declare p public.publications;
begin
 select * into p from public.publications where id = NEW.publication_id;
 perform public.notify(p.owner_id, 'review_request', 'Calificá a ' || NEW.sender_name,
  'Contá cómo fue la permuta de "' || p.title || '". Tenés 14 días.', NEW.id, p.id);
 perform public.notify(NEW.sender_id, 'review_request', 'Calificá a ' || p.owner_name,
  'Contá cómo fue la permuta de "' || p.title || '". Tenés 14 días.', NEW.id, p.id);
 return NEW;
end;
$$;
create trigger request_reviews after update of status on public.offers
 for each row when (OLD.status <> 'completed' and NEW.status = 'completed')
 execute function public.request_reviews();

create or replace function public.submit_review(offer_id uuid, rating int, comment text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare o public.offers; p public.publications; reviewed uuid; reviewer_name text; clean_comment text := nullif(trim(coalesce(comment, '')), '');
begin
 if auth.uid() is null then raise exception 'Ingresá a tu cuenta.'; end if;
 if rating is null or rating not between 1 and 5 then raise exception 'Elegí entre 1 y 5 estrellas.'; end if;
 if char_length(coalesce(clean_comment, '')) > 500 then raise exception 'El comentario puede tener hasta 500 caracteres.'; end if;
 select * into o from public.offers x where x.id = offer_id for update;
 if not found then raise exception 'La permuta ya no existe.'; end if;
 select * into p from public.publications where id = o.publication_id;
 if o.status <> 'completed' then raise exception 'Solo se pueden calificar permutas concretadas.'; end if;
 if auth.uid() = p.owner_id then reviewed := o.sender_id;
 elsif auth.uid() = o.sender_id then reviewed := p.owner_id;
 else raise exception 'No tenés permiso para esta acción.'; end if;
 if public.trade_completed_at(o) + interval '14 days' <= now() then raise exception 'Pasaron más de 14 días desde la permuta; ya no se puede calificar.'; end if;
 if exists (select 1 from public.reviews r where r.offer_id = o.id and r.reviewer_id = auth.uid()) then raise exception 'Ya calificaste esta permuta.'; end if;

 insert into public.reviews (offer_id, reviewer_id, reviewed_id, rating, comment) values (o.id, auth.uid(), reviewed, rating, clean_comment);
 select display_name into reviewer_name from public.profiles where id = auth.uid();

 if exists (select 1 from public.reviews r where r.offer_id = o.id and r.reviewer_id = reviewed) then
  update public.reviews r set published_at = now() where r.offer_id = o.id and r.published_at is null;
  perform public.notify(reviewed, 'review_published', 'Ya podés ver tu calificación', reviewer_name || ' también calificó la permuta de "' || p.title || '". Las dos opiniones ya son públicas.', o.id, p.id);
  perform public.notify(auth.uid(), 'review_published', 'Ya podés ver tu calificación', 'Las dos opiniones sobre la permuta de "' || p.title || '" ya son públicas.', o.id, p.id);
  return 'published';
 end if;
 perform public.notify(reviewed, 'review_pending', reviewer_name || ' ya te calificó',
  'Calificalo vos también para que se publiquen las dos opiniones. Tenés hasta el ' || public.ar_date(public.trade_completed_at(o) + interval '14 days') || '.', o.id, p.id);
 return 'waiting';
end;
$$;

-- Tarea automática: recordatorio a los 3 días y publicación a los 14.
create or replace function public.process_review_deadlines()
returns void language plpgsql security definer set search_path = '' as $$
declare r record;
begin
 for r in select o.id, o.sender_id, o.sender_name, p.owner_id, p.owner_name, p.title, p.id as pub_id, public.trade_completed_at(o) as done_at
  from public.offers o join public.publications p on p.id = o.publication_id
  where o.status = 'completed' and o.review_reminders = 0
   and public.trade_completed_at(o) <= now() - interval '3 days' and public.trade_completed_at(o) > now() - interval '14 days'
  for update of o
 loop
  if not exists (select 1 from public.reviews x where x.offer_id = r.id and x.reviewer_id = r.owner_id) then
   perform public.notify(r.owner_id, 'review_reminder', 'Todavía no calificaste a ' || r.sender_name,
    'Tenés hasta el ' || public.ar_date(r.done_at + interval '14 days') || ' para calificar la permuta de "' || r.title || '".', r.id, r.pub_id);
  end if;
  if not exists (select 1 from public.reviews x where x.offer_id = r.id and x.reviewer_id = r.sender_id) then
   perform public.notify(r.sender_id, 'review_reminder', 'Todavía no calificaste a ' || r.owner_name,
    'Tenés hasta el ' || public.ar_date(r.done_at + interval '14 days') || ' para calificar la permuta de "' || r.title || '".', r.id, r.pub_id);
  end if;
  update public.offers set review_reminders = 1 where id = r.id;
 end loop;

 for r in update public.reviews rv set published_at = now()
  from public.offers o
  where o.id = rv.offer_id and rv.published_at is null and public.trade_completed_at(o) + interval '14 days' <= now()
  returning rv.reviewed_id, rv.offer_id, o.publication_id
 loop
  perform public.notify(r.reviewed_id, 'review_published', 'Recibiste una calificación', 'Ya podés ver en tu perfil la opinión sobre una permuta.', r.offer_id, r.publication_id);
 end loop;
end;
$$;

-- Estadísticas del perfil con calificaciones.
create or replace function public.get_profile_stats(target_user uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
 with pubs as (
  select status, expires_at, created_at from public.publications where owner_id = target_user
 ), received as (
  select o.status, o.created_at, o.updated_at
  from public.offers o join public.publications p on p.id = o.publication_id
  where p.owner_id = target_user and o.status <> 'cancelled'
 ), involved as (
  select o.status, o.owner_response, o.sender_response, (p.owner_id = target_user) as is_owner
  from public.offers o join public.publications p on p.id = o.publication_id
  where p.owner_id = target_user or o.sender_id = target_user
 ), ratings as (
  select rating from public.reviews where reviewed_id = target_user and published_at is not null
 )
 select jsonb_build_object(
  'active_publications', (select count(*) from pubs where status = 'active' and expires_at > now()),
  'reserved_publications', (select count(*) from pubs where status = 'reserved'),
  'exchanged_publications', (select count(*) from pubs where status = 'exchanged'),
  'completed_trades', (select count(*) from involved where status = 'completed'),
  'unanswered_trades', (select count(*) from involved where status = 'abandoned'
    and ((is_owner and owner_response is null) or (not is_owner and sender_response is null))),
  'offers_received', (select count(*) from received),
  'offers_answered', (select count(*) from received where status not in ('pending','expired')),
  'avg_response_hours', (select round(extract(epoch from avg(updated_at - created_at)) / 3600) from received where status in ('accepted','rejected','completed','failed','abandoned')),
  'rating_avg', (select round(avg(rating), 1) from ratings),
  'rating_count', (select count(*) from ratings),
  'last_activity', (select greatest(
    (select max(created_at) from pubs),
    (select max(created_at) from public.offers where sender_id = target_user),
    (select max(created_at) from public.offer_messages where sender_id = target_user)
   )::date)
 )
 where exists (select 1 from public.profiles where id = target_user);
$$;

revoke all on function public.request_reviews() from public, anon, authenticated;
revoke all on function public.process_review_deadlines() from public, anon, authenticated;
revoke all on function public.submit_review(uuid,int,text) from public, anon;
grant execute on function public.submit_review(uuid,int,text) to authenticated;
commit;

-- ---------- Programar la tarea automática de calificaciones (cada hora) ----------
select cron.schedule('permuton-reviews', '7 * * * *', 'select public.process_review_deadlines()');
