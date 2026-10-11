-- Ejecutar una vez después de migration-09.
-- Bloqueos entre usuarios, reportes y moderación.
-- Para hacerte administrador, ver el README (no se guarda ningún email en este archivo).
begin;

-- ---------- Administradores ----------
create table public.admins (
 user_id uuid primary key references auth.users(id) on delete cascade,
 created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
create policy "read own admin row" on public.admins for select to authenticated using (user_id = (select auth.uid()));
revoke all on public.admins from anon, authenticated;
grant select on public.admins to authenticated;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
 select exists (select 1 from public.admins where user_id = auth.uid());
$$;
grant execute on function public.is_admin() to anon, authenticated;

-- ---------- Suspensión y publicaciones ocultas ----------
alter table public.profiles add column suspended_at timestamptz;
alter table public.publications add column hidden_at timestamptz;
alter table public.publications add column hidden_reason text check (hidden_reason in ('reports','moderation'));

create or replace function public.is_suspended(user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
 select exists (select 1 from public.profiles where id = user_id and suspended_at is not null);
$$;
grant execute on function public.is_suspended(uuid) to anon, authenticated;

-- ---------- Bloqueos ----------
create table public.blocks (
 blocker_id uuid not null,
 blocked_id uuid not null,
 created_at timestamptz not null default now(),
 primary key (blocker_id, blocked_id),
 constraint blocks_blocker_id_fkey foreign key (blocker_id) references public.profiles(id) on delete cascade,
 constraint blocks_blocked_id_fkey foreign key (blocked_id) references public.profiles(id) on delete cascade,
 constraint blocks_not_self check (blocker_id <> blocked_id)
);
alter table public.blocks enable row level security;
-- Solo quien bloquea ve sus bloqueos; la persona bloqueada no se entera.
create policy "read own blocks" on public.blocks for select to authenticated using (blocker_id = (select auth.uid()));
create policy "create own blocks" on public.blocks for insert to authenticated with check (blocker_id = (select auth.uid()));
create policy "delete own blocks" on public.blocks for delete to authenticated using (blocker_id = (select auth.uid()));
revoke all on public.blocks from anon, authenticated;
grant select, delete on public.blocks to authenticated;
grant insert (blocker_id, blocked_id) on public.blocks to authenticated;

create or replace function public.blocked_between(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
 select exists (select 1 from public.blocks where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a));
$$;
revoke all on function public.blocked_between(uuid,uuid) from public, anon;
grant execute on function public.blocked_between(uuid,uuid) to authenticated;

-- ¿El usuario actual bloqueó a target? (los visitantes sin cuenta no tienen acceso a la tabla de bloqueos)
create or replace function public.i_blocked(target uuid)
returns boolean language sql stable security definer set search_path = '' as $$
 select auth.uid() is not null and exists (select 1 from public.blocks where blocker_id = auth.uid() and blocked_id = target);
$$;
grant execute on function public.i_blocked(uuid) to anon, authenticated;

-- Al bloquear, se cierran las propuestas pendientes entre los dos (sin revelar el motivo).
create or replace function public.close_offers_on_block()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r record;
begin
 for r in update public.offers o set status = 'rejected', updated_at = now()
  from public.publications p
  where p.id = o.publication_id and o.status = 'pending' and p.owner_id = NEW.blocker_id and o.sender_id = NEW.blocked_id
  returning o.id, o.sender_id, p.id as pub_id, p.title
 loop
  perform public.notify(r.sender_id, 'offer_rejected', 'Rechazaron tu propuesta', 'El dueño de "' || r.title || '" rechazó tu propuesta.', r.id, r.pub_id);
 end loop;
 for r in update public.offers o set status = 'cancelled', updated_at = now()
  from public.publications p
  where p.id = o.publication_id and o.status = 'pending' and p.owner_id = NEW.blocked_id and o.sender_id = NEW.blocker_id
  returning o.id, o.sender_name, p.owner_id, p.id as pub_id, p.title
 loop
  perform public.notify(r.owner_id, 'offer_cancelled', 'Cancelaron una propuesta', r.sender_name || ' canceló su propuesta por "' || r.title || '".', r.id, r.pub_id);
 end loop;
 return NEW;
end;
$$;
create trigger close_offers_on_block after insert on public.blocks
 for each row execute function public.close_offers_on_block();

-- ---------- Visibilidad de publicaciones ----------
drop policy "read public publications" on public.publications;
create policy "read public publications" on public.publications for select to anon, authenticated
 using (
  owner_id = (select auth.uid())
  or (select public.is_admin())
  or (
   ((status = 'active' and expires_at > now()) or status in ('reserved','exchanged'))
   and hidden_at is null
   and not public.is_suspended(owner_id)
   and not public.i_blocked(owner_id)
  )
 );

-- Publicar, aceptar y reactivar respetan suspensión y ocultamiento.
create or replace function public.validate_publication_state()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
 if TG_OP = 'INSERT' and (NEW.province_id is null or NEW.locality_id is null) then
  raise exception 'Seleccioná provincia y localidad de Argentina.';
 end if;
 if TG_OP = 'INSERT' and public.is_suspended(NEW.owner_id) then
  raise exception 'Tu cuenta está suspendida: no podés publicar.';
 end if;
 if NEW.status = 'active' and exists (select 1 from public.offers o where o.publication_id = NEW.id and o.status = 'accepted') then
  raise exception 'Esta publicación ya tiene una permuta aceptada y no puede reactivarse.';
 end if;
 if TG_OP = 'UPDATE' and OLD.status = 'active' and NEW.status = 'reserved' then
  if NEW.hidden_at is not null then raise exception 'La publicación está oculta por moderación.'; end if;
  if public.is_suspended(NEW.owner_id) then raise exception 'Tu cuenta está suspendida.'; end if;
 end if;
 return NEW;
end;
$$;

create or replace function public.validate_offer_publication()
returns trigger language plpgsql security definer set search_path = '' as $$
declare p public.publications;
begin
 select * into p from public.publications where id = NEW.publication_id for update;
 if not found or p.status <> 'active' or p.expires_at <= now() or p.hidden_at is not null or public.is_suspended(p.owner_id) then
  raise exception 'La publicación ya no está disponible para permutar.';
 end if;
 if public.is_suspended(NEW.sender_id) then raise exception 'Tu cuenta está suspendida: no podés enviar propuestas.'; end if;
 if public.blocked_between(p.owner_id, NEW.sender_id) then raise exception 'No podés enviar propuestas a este usuario.'; end if;
 if NEW.status <> 'pending' then raise exception 'La propuesta debe comenzar pendiente.'; end if;
 return NEW;
end;
$$;

-- El chat se corta si hay bloqueo o suspensión (el historial sigue visible).
create or replace function public.can_access_offer_chat(target_offer uuid, sending boolean default false)
returns boolean language sql stable security definer set search_path = '' as $$
 select exists (
  select 1 from public.offers o join public.publications p on p.id = o.publication_id
  where o.id = target_offer and auth.uid() is not null
  and (o.sender_id = auth.uid() or p.owner_id = auth.uid())
  and (not sending or (o.status in ('pending','accepted')
   and not public.blocked_between(o.sender_id, p.owner_id)
   and not public.is_suspended(o.sender_id) and not public.is_suspended(p.owner_id)))
 );
$$;

-- ---------- Reportes ----------
create table public.reports (
 id uuid primary key default gen_random_uuid(),
 reporter_id uuid not null,
 target_user_id uuid not null,
 publication_id uuid references public.publications(id) on delete set null,
 reason text not null check (reason in ('scam','fake_listing','prohibited','offensive','spam','other')),
 details text check (details is null or char_length(details) <= 500),
 status text not null default 'open' check (status in ('open','dismissed','actioned')),
 created_at timestamptz not null default now(),
 resolved_at timestamptz,
 resolved_by uuid references auth.users(id) on delete set null,
 constraint reports_reporter_id_fkey foreign key (reporter_id) references public.profiles(id) on delete cascade,
 constraint reports_target_user_id_fkey foreign key (target_user_id) references public.profiles(id) on delete cascade,
 constraint reports_not_self check (reporter_id <> target_user_id)
);
create unique index reports_once_per_reason on public.reports (reporter_id, target_user_id, coalesce(publication_id, '00000000-0000-0000-0000-000000000000'::uuid), reason);
create index reports_open_idx on public.reports (created_at desc) where status = 'open';
alter table public.reports enable row level security;
create policy "admins read reports" on public.reports for select to authenticated using ((select public.is_admin()));
revoke all on public.reports from anon, authenticated;
grant select on public.reports to authenticated;

create or replace function public.submit_report(target_user uuid, publication uuid, reason text, details text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare p public.publications; target uuid := target_user; clean text := nullif(trim(coalesce(details, '')), ''); reporters int; a record; reporter_name text;
begin
 if auth.uid() is null then raise exception 'Ingresá a tu cuenta.'; end if;
 if reason is null or reason not in ('scam','fake_listing','prohibited','offensive','spam','other') then raise exception 'Elegí un motivo.'; end if;
 if char_length(coalesce(clean, '')) > 500 then raise exception 'El detalle puede tener hasta 500 caracteres.'; end if;
 if publication is not null then
  select * into p from public.publications where id = publication for update;
  if not found then raise exception 'La publicación ya no existe.'; end if;
  target := p.owner_id;
 end if;
 if target is null or not exists (select 1 from public.profiles where id = target) then raise exception 'El usuario ya no existe.'; end if;
 if target = auth.uid() then raise exception 'No podés reportarte a vos mismo.'; end if;
 begin
  insert into public.reports (reporter_id, target_user_id, publication_id, reason, details) values (auth.uid(), target, publication, reason, clean);
 exception when unique_violation then raise exception 'Ya enviaste un reporte por este motivo.';
 end;
 select display_name into reporter_name from public.profiles where id = auth.uid();
 for a in select user_id from public.admins loop
  perform public.notify(a.user_id, 'report_new', 'Nuevo reporte', reporter_name || ' envió un reporte' || case when publication is not null then ' sobre "' || p.title || '"' else '' end || '.', null, publication);
 end loop;

 -- Con 3 personas distintas que reportan la misma publicación, se oculta hasta revisarla.
 if publication is not null and p.hidden_at is null then
  select count(distinct reporter_id) into reporters from public.reports r where r.publication_id = publication and r.status = 'open';
  if reporters >= 3 then
   update public.publications set hidden_at = now(), hidden_reason = 'reports' where id = publication;
   perform public.notify(p.owner_id, 'publication_hidden', 'Ocultamos tu publicación',
    '"' || p.title || '" recibió varios reportes y quedó oculta hasta que la revisemos.', null, publication);
   return 'hidden';
  end if;
 end if;
 return 'sent';
end;
$$;

-- ---------- Acciones de moderación (solo administradores) ----------
create or replace function public.admin_dismiss_report(report_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if not public.is_admin() then raise exception 'Solo administradores.'; end if;
 update public.reports set status = 'dismissed', resolved_at = now(), resolved_by = auth.uid() where id = report_id and status = 'open';
end;
$$;

create or replace function public.admin_set_publication_hidden(publication_id uuid, hidden boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare p public.publications;
begin
 if not public.is_admin() then raise exception 'Solo administradores.'; end if;
 select * into p from public.publications where id = publication_id for update;
 if not found then raise exception 'La publicación ya no existe.'; end if;
 if hidden then
  update public.publications set hidden_at = now(), hidden_reason = 'moderation' where id = p.id;
  update public.reports r set status = 'actioned', resolved_at = now(), resolved_by = auth.uid() where r.publication_id = p.id and r.status = 'open';
  perform public.notify(p.owner_id, 'publication_hidden', 'Ocultamos tu publicación', '"' || p.title || '" no cumple las reglas de permutON y quedó oculta.', null, p.id);
 else
  update public.publications set hidden_at = null, hidden_reason = null where id = p.id;
  update public.reports r set status = 'dismissed', resolved_at = now(), resolved_by = auth.uid() where r.publication_id = p.id and r.status = 'open';
  perform public.notify(p.owner_id, 'publication_restored', 'Tu publicación volvió a estar visible', 'Revisamos "' || p.title || '" y ya se muestra de nuevo.', null, p.id);
 end if;
end;
$$;

create or replace function public.admin_set_user_suspended(target_user uuid, suspended boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if not public.is_admin() then raise exception 'Solo administradores.'; end if;
 if exists (select 1 from public.admins where user_id = target_user) then raise exception 'No se puede suspender a un administrador.'; end if;
 if suspended then
  update public.profiles set suspended_at = now() where id = target_user;
  update public.reports set status = 'actioned', resolved_at = now(), resolved_by = auth.uid() where target_user_id = target_user and status = 'open';
  perform public.notify(target_user, 'account_suspended', 'Tu cuenta fue suspendida', 'Por incumplir las reglas de permutON no podés publicar, proponer ni chatear. Tus publicaciones quedaron ocultas.');
 else
  update public.profiles set suspended_at = null where id = target_user;
  perform public.notify(target_user, 'account_restored', 'Tu cuenta volvió a estar activa', 'Ya podés volver a usar permutON con normalidad.');
 end if;
end;
$$;

revoke all on function public.close_offers_on_block() from public, anon, authenticated;
revoke all on function public.submit_report(uuid,uuid,text,text) from public, anon;
revoke all on function public.admin_dismiss_report(uuid) from public, anon;
revoke all on function public.admin_set_publication_hidden(uuid,boolean) from public, anon;
revoke all on function public.admin_set_user_suspended(uuid,boolean) from public, anon;
grant execute on function public.submit_report(uuid,uuid,text,text) to authenticated;
grant execute on function public.admin_dismiss_report(uuid) to authenticated;
grant execute on function public.admin_set_publication_hidden(uuid,boolean) to authenticated;
grant execute on function public.admin_set_user_suspended(uuid,boolean) to authenticated;
commit;
