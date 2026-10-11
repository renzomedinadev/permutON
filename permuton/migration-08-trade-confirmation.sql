-- Ejecutar una vez después de migration-07.
-- Notificaciones, confirmación de permutas por ambas partes y vencimiento de publicaciones.
-- Al final se programa la tarea automática (Cron). Si esa parte falla, ver el README.
begin;

-- ---------- Notificaciones ----------
create table public.notifications (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 kind text not null,
 title text not null,
 body text not null,
 offer_id uuid references public.offers(id) on delete set null,
 publication_id uuid references public.publications(id) on delete set null,
 read_at timestamptz,
 created_at timestamptz not null default now()
);
create index notifications_user_recent_idx on public.notifications (user_id, created_at desc);
create index notifications_user_unread_idx on public.notifications (user_id) where read_at is null;
alter table public.notifications enable row level security;
create policy "read own notifications" on public.notifications for select to authenticated using (user_id = (select auth.uid()));
create policy "mark own notifications" on public.notifications for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
revoke all on public.notifications from anon, authenticated;
grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;

create or replace function public.notify(target uuid, kind text, title text, body text, offer uuid default null, publication uuid default null)
returns void language sql security definer set search_path = '' as $$
 insert into public.notifications (user_id, kind, title, body, offer_id, publication_id)
 values (target, kind, title, body, offer, publication);
$$;

create or replace function public.ar_date(ts timestamptz)
returns text language sql stable set search_path = '' as $$
 select to_char(ts at time zone 'America/Argentina/Buenos_Aires', 'DD/MM HH24:MI');
$$;

-- ---------- Columnas nuevas ----------
alter table public.publications add column expires_at timestamptz not null default (now() + interval '14 days');
-- 0 = sin aviso, 1 = avisado que vence pronto, 2 = avisado que venció.
alter table public.publications add column expiry_notice smallint not null default 0 check (expiry_notice between 0 and 2);
create index publications_expiry_idx on public.publications (expires_at) where status = 'active';

alter table public.offers drop constraint offers_status_check;
alter table public.offers add constraint offers_status_check
 check (status in ('pending','accepted','rejected','cancelled','completed','failed','abandoned','expired'));
alter table public.offers add column accepted_at timestamptz;
alter table public.offers add column owner_response text check (owner_response in ('confirmed','failed'));
alter table public.offers add column owner_responded_at timestamptz;
alter table public.offers add column sender_response text check (sender_response in ('confirmed','failed'));
alter table public.offers add column sender_responded_at timestamptz;
alter table public.offers add column reminders_sent smallint not null default 0;
create index offers_accepted_idx on public.offers (accepted_at) where status = 'accepted';

-- Datos anteriores: lo ya marcado como intercambiado se da por concretado;
-- las permutas aceptadas en curso arrancan sus 5 días ahora.
update public.offers o set status = 'completed', accepted_at = o.updated_at
from public.publications p where p.id = o.publication_id and o.status = 'accepted' and p.status = 'exchanged';
update public.offers set accepted_at = now() where status = 'accepted';

-- ---------- Visibilidad y permisos de publicaciones ----------
drop policy "read public publications" on public.publications;
create policy "read public publications" on public.publications for select to anon, authenticated
 using ((status = 'active' and expires_at > now()) or status in ('reserved','exchanged') or owner_id = (select auth.uid()));

-- Estado y vencimiento solo cambian mediante las funciones de la base.
revoke insert, update on public.publications from anon, authenticated;
grant insert (owner_id, owner_name, title, category, description, owned_time, reason, wanted, photo_path, photo_paths, province_id, locality_id) on public.publications to authenticated;
grant update (owner_name, title, category, description, owned_time, reason, wanted, photo_path, photo_paths, province_id, locality_id) on public.publications to authenticated;

create or replace function public.validate_offer_publication()
returns trigger language plpgsql security definer set search_path = '' as $$
declare p public.publications;
begin
 select * into p from public.publications where id = NEW.publication_id for update;
 if not found or p.status <> 'active' or p.expires_at <= now() then raise exception 'La publicación ya no está disponible para permutar.'; end if;
 if NEW.status <> 'pending' then raise exception 'La propuesta debe comenzar pendiente.'; end if;
 return NEW;
end;
$$;

create or replace function public.renew_publication(publication_id uuid)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare p public.publications; new_expiry timestamptz := now() + interval '14 days';
begin
 if auth.uid() is null then raise exception 'Ingresá a tu cuenta.'; end if;
 select * into p from public.publications where id = publication_id for update;
 if not found or p.owner_id <> auth.uid() then raise exception 'No tenés permiso para esta acción.'; end if;
 if p.status <> 'active' then raise exception 'Solo se pueden renovar publicaciones disponibles.'; end if;
 update public.publications set expires_at = new_expiry, expiry_notice = 0 where id = p.id;
 return new_expiry;
end;
$$;

-- ---------- Avisos de propuestas ----------
create or replace function public.notify_new_offer()
returns trigger language plpgsql security definer set search_path = '' as $$
declare p public.publications;
begin
 select * into p from public.publications where id = NEW.publication_id;
 perform public.notify(p.owner_id, 'offer_received', 'Recibiste una propuesta',
  NEW.sender_name || ' te ofrece "' || coalesce(NEW.title, 'un objeto') || '" por "' || p.title || '".', NEW.id, p.id);
 return NEW;
end;
$$;
create trigger notify_new_offer after insert on public.offers
 for each row execute function public.notify_new_offer();

create or replace function public.change_offer_status(offer_id uuid, new_status text)
returns text language plpgsql security definer set search_path = '' as $$
declare selected_offer public.offers; p public.publications; target_publication uuid; r record;
begin
 if auth.uid() is null then raise exception 'Ingresá a tu cuenta.'; end if;
 if new_status is null or new_status not in ('accepted','rejected','cancelled') then raise exception 'Estado inválido.'; end if;
 select o.publication_id into target_publication from public.offers o where o.id = offer_id;
 if not found then raise exception 'La propuesta ya no existe.'; end if;
 -- Siempre bloquear publicación primero para evitar aceptaciones simultáneas.
 select * into p from public.publications where id = target_publication for update;
 if not found then raise exception 'La publicación ya no existe.'; end if;
 select * into selected_offer from public.offers o where o.id = offer_id for update;
 if not found then raise exception 'La propuesta ya no existe.'; end if;
 if not ((new_status in ('accepted','rejected') and p.owner_id = auth.uid())
 or (new_status = 'cancelled' and selected_offer.sender_id = auth.uid())) then raise exception 'No tenés permiso para esta acción.'; end if;
 if selected_offer.status <> 'pending' then raise exception 'La propuesta ya fue resuelta. Actualizá la lista.'; end if;
 if new_status = 'accepted' and (p.status <> 'active' or p.expires_at <= now()) then
  raise exception 'La publicación no está disponible o está vencida. Renovala para aceptar propuestas.';
 end if;
 update public.offers o set status = new_status, updated_at = now(),
  accepted_at = case when new_status = 'accepted' then now() else o.accepted_at end
 where o.id = offer_id;
 if new_status = 'accepted' then
  update public.publications set status = 'reserved' where id = p.id;
  for r in update public.offers o set status = 'rejected', updated_at = now()
   where o.publication_id = p.id and o.id <> offer_id and o.status = 'pending' returning o.id, o.sender_id
  loop
   perform public.notify(r.sender_id, 'offer_rejected', 'Tu propuesta no fue elegida', 'El dueño de "' || p.title || '" aceptó otra propuesta.', r.id, p.id);
  end loop;
  perform public.notify(selected_offer.sender_id, 'offer_accepted', '¡Aceptaron tu propuesta!',
   'Coordiná la permuta de "' || p.title || '" por el chat. Cuando se haga, confirmalo en Mis propuestas antes del ' || public.ar_date(now() + interval '5 days') || '.', offer_id, p.id);
 elsif new_status = 'rejected' then
  perform public.notify(selected_offer.sender_id, 'offer_rejected', 'Rechazaron tu propuesta', 'El dueño de "' || p.title || '" rechazó tu propuesta.', offer_id, p.id);
 else
  perform public.notify(p.owner_id, 'offer_cancelled', 'Cancelaron una propuesta', selected_offer.sender_name || ' canceló su propuesta por "' || p.title || '".', offer_id, p.id);
 end if;
 return new_status;
end;
$$;

-- ---------- Confirmación de la permuta ----------
create or replace function public.respond_trade(offer_id uuid, result text)
returns text language plpgsql security definer set search_path = '' as $$
declare o public.offers; p public.publications; target_publication uuid; is_owner boolean; other_user uuid;
begin
 if auth.uid() is null then raise exception 'Ingresá a tu cuenta.'; end if;
 if result is null or result not in ('confirmed','failed') then raise exception 'Respuesta inválida.'; end if;
 select x.publication_id into target_publication from public.offers x where x.id = offer_id;
 if not found then raise exception 'La propuesta ya no existe.'; end if;
 select * into p from public.publications where id = target_publication for update;
 select * into o from public.offers x where x.id = offer_id for update;
 if o.status <> 'accepted' then raise exception 'Esta permuta ya fue cerrada. Actualizá la lista.'; end if;
 is_owner := p.owner_id = auth.uid();
 if not is_owner and o.sender_id <> auth.uid() then raise exception 'No tenés permiso para esta acción.'; end if;
 if (is_owner and o.owner_response is not null) or (not is_owner and o.sender_response is not null) then raise exception 'Ya respondiste esta permuta.'; end if;
 other_user := case when is_owner then o.sender_id else p.owner_id end;

 if is_owner then
  update public.offers x set owner_response = result, owner_responded_at = now(), updated_at = now() where x.id = offer_id returning * into o;
 else
  update public.offers x set sender_response = result, sender_responded_at = now(), updated_at = now() where x.id = offer_id returning * into o;
 end if;

 if result = 'failed' then
  update public.offers x set status = 'failed', updated_at = now() where x.id = offer_id;
  update public.publications set status = 'active', expires_at = greatest(expires_at, now() + interval '14 days'), expiry_notice = 0 where id = p.id;
  perform public.notify(other_user, 'trade_failed', 'La permuta no se concretó',
   'La otra parte indicó que la permuta de "' || p.title || '" no se concretó.' || case when is_owner then '' else ' Tu publicación volvió al catálogo.' end, offer_id, p.id);
  return 'failed';
 end if;

 if o.owner_response = 'confirmed' and o.sender_response = 'confirmed' then
  update public.offers x set status = 'completed', updated_at = now() where x.id = offer_id;
  update public.publications set status = 'exchanged' where id = p.id;
  perform public.notify(p.owner_id, 'trade_completed', '¡Permuta concretada!', 'Las dos partes confirmaron la permuta de "' || p.title || '".', offer_id, p.id);
  perform public.notify(o.sender_id, 'trade_completed', '¡Permuta concretada!', 'Las dos partes confirmaron la permuta de "' || p.title || '".', offer_id, p.id);
  return 'completed';
 end if;

 perform public.notify(other_user, 'trade_waiting', 'Falta tu confirmación',
  'La otra parte confirmó que la permuta de "' || p.title || '" se concretó. Respondé en Mis propuestas antes del ' || public.ar_date(o.accepted_at + interval '5 days') || '.', offer_id, p.id);
 return 'waiting';
end;
$$;

-- ---------- Tarea automática: recordatorios y vencimientos ----------
create or replace function public.process_deadlines()
returns void language plpgsql security definer set search_path = '' as $$
declare r record; r2 record; deadline text; stage smallint;
begin
 -- Recordatorios a los 2 y 3 días de aceptada.
 for r in select o.id, o.sender_id, o.owner_response, o.sender_response, o.accepted_at, o.reminders_sent, p.owner_id, p.title, p.id as pub_id
  from public.offers o join public.publications p on p.id = o.publication_id
  where o.status = 'accepted' and o.accepted_at <= now() - interval '2 days' and o.accepted_at > now() - interval '5 days'
   and o.reminders_sent < (case when o.accepted_at <= now() - interval '3 days' then 2 else 1 end)
  for update of o
 loop
  stage := case when r.accepted_at <= now() - interval '3 days' then 2 else 1 end;
  deadline := public.ar_date(r.accepted_at + interval '5 days');
  if r.owner_response is null then
   perform public.notify(r.owner_id, 'trade_reminder', 'Respondé si se concretó la permuta',
    'Tenés hasta el ' || deadline || ' para confirmar la permuta de "' || r.title || '". Si no respondés, se cancela y tu publicación queda vencida.', r.id, r.pub_id);
  end if;
  if r.sender_response is null then
   perform public.notify(r.sender_id, 'trade_reminder', 'Respondé si se concretó la permuta',
    'Tenés hasta el ' || deadline || ' para confirmar la permuta de "' || r.title || '". Si no respondés, se cancela y queda registrado en tu perfil.', r.id, r.pub_id);
  end if;
  update public.offers set reminders_sent = stage where id = r.id;
 end loop;

 -- A los 5 días sin las dos respuestas, la permuta se cancela.
 for r in select o.id, o.sender_id, o.owner_response, o.sender_response, p.owner_id, p.title, p.id as pub_id
  from public.offers o join public.publications p on p.id = o.publication_id
  where o.status = 'accepted' and o.accepted_at <= now() - interval '5 days'
  for update of o, p
 loop
  update public.offers set status = 'abandoned', updated_at = now() where id = r.id;
  if r.owner_response is null then
   update public.publications set status = 'active', expires_at = now(), expiry_notice = 2 where id = r.pub_id;
   perform public.notify(r.owner_id, 'trade_abandoned', 'Se canceló una permuta por falta de respuesta',
    'No confirmaste la permuta de "' || r.title || '" en 5 días. La publicación quedó vencida: renovala desde Mis publicaciones para volver a ofrecerla.', r.id, r.pub_id);
  else
   update public.publications set status = 'active', expires_at = greatest(expires_at, now() + interval '14 days'), expiry_notice = 0 where id = r.pub_id;
   perform public.notify(r.owner_id, 'trade_abandoned', 'Tu publicación volvió al catálogo',
    'La otra parte no confirmó la permuta de "' || r.title || '" en 5 días. Tu publicación vuelve a estar disponible para otras propuestas.', r.id, r.pub_id);
  end if;
  if r.sender_response is null then
   perform public.notify(r.sender_id, 'trade_abandoned', 'Se canceló una permuta por falta de respuesta',
    'No confirmaste en 5 días la permuta de "' || r.title || '". Quedó registrado en tu perfil.', r.id, r.pub_id);
  else
   perform public.notify(r.sender_id, 'trade_abandoned', 'Se canceló la permuta',
    'El dueño de "' || r.title || '" no respondió en 5 días, así que la permuta se canceló.', r.id, r.pub_id);
  end if;
 end loop;

 -- Aviso 2 días antes de que venza una publicación.
 for r in select id, owner_id, title, expires_at from public.publications
  where status = 'active' and expiry_notice = 0 and expires_at > now() and expires_at <= now() + interval '2 days'
  for update
 loop
  perform public.notify(r.owner_id, 'publication_expiring', 'Tu publicación vence pronto',
   '"' || r.title || '" vence el ' || public.ar_date(r.expires_at) || '. Renovala desde Mis publicaciones para que siga visible.', null, r.id);
  update public.publications set expiry_notice = 1 where id = r.id;
 end loop;

 -- Publicaciones vencidas: se ocultan (por la regla de lectura) y vencen sus propuestas pendientes.
 for r in select id, owner_id, title from public.publications
  where status = 'active' and expiry_notice < 2 and expires_at <= now()
  for update
 loop
  perform public.notify(r.owner_id, 'publication_expired', 'Tu publicación venció',
   '"' || r.title || '" ya no se muestra a los demás. Renovala desde Mis publicaciones para volver a ofrecerla.', null, r.id);
  update public.publications set expiry_notice = 2 where id = r.id;
  for r2 in update public.offers set status = 'expired', updated_at = now()
   where publication_id = r.id and status = 'pending' returning id, sender_id
  loop
   perform public.notify(r2.sender_id, 'offer_expired', 'Una propuesta tuya venció',
    'La publicación "' || r.title || '" venció sin que respondieran tu propuesta.', r2.id, r.id);
  end loop;
 end loop;
end;
$$;

-- ---------- Estadísticas del perfil ----------
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
  'last_activity', (select greatest(
    (select max(created_at) from pubs),
    (select max(created_at) from public.offers where sender_id = target_user),
    (select max(created_at) from public.offer_messages where sender_id = target_user)
   )::date)
 )
 where exists (select 1 from public.profiles where id = target_user);
$$;

revoke all on function public.notify(uuid,text,text,text,uuid,uuid) from public, anon, authenticated;
revoke all on function public.process_deadlines() from public, anon, authenticated;
revoke all on function public.notify_new_offer() from public, anon, authenticated;
revoke all on function public.renew_publication(uuid) from public, anon;
revoke all on function public.respond_trade(uuid,text) from public, anon;
grant execute on function public.renew_publication(uuid) to authenticated;
grant execute on function public.respond_trade(uuid,text) to authenticated;
commit;

-- ---------- Programar la tarea automática cada 15 minutos ----------
-- Si esto da error, activá Cron en Supabase > Integrations > Cron y volvé a ejecutar solo estas dos líneas.
create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('permuton-deadlines', '*/15 * * * *', 'select public.process_deadlines()');
