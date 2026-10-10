-- Ejecutar una vez después de migration-06.
-- Perfil público: historial de publicaciones y estadísticas calculadas en la base.
begin;

-- Las publicaciones reservadas e intercambiadas pasan a ser visibles para el historial del perfil.
-- El catálogo sigue mostrando solo las activas porque la app filtra por estado.
drop policy "read active or owned publications" on public.publications;
create policy "read public publications" on public.publications for select to anon, authenticated
 using (status in ('active','reserved','exchanged') or owner_id = (select auth.uid()));

-- Estadísticas públicas de un usuario. Lee propuestas y mensajes sin exponer su contenido.
create or replace function public.get_profile_stats(target_user uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
 with pubs as (
  select status, created_at from public.publications where owner_id = target_user
 ), received as (
  select o.status, o.created_at, o.updated_at
  from public.offers o join public.publications p on p.id = o.publication_id
  where p.owner_id = target_user and o.status <> 'cancelled'
 ), trades as (
  select o.id from public.offers o join public.publications p on p.id = o.publication_id
  where o.status = 'accepted' and (p.owner_id = target_user or o.sender_id = target_user)
 )
 select jsonb_build_object(
  'active_publications', (select count(*) from pubs where status = 'active'),
  'reserved_publications', (select count(*) from pubs where status = 'reserved'),
  'exchanged_publications', (select count(*) from pubs where status = 'exchanged'),
  'accepted_trades', (select count(*) from trades),
  'offers_received', (select count(*) from received),
  'offers_answered', (select count(*) from received where status in ('accepted','rejected')),
  'avg_response_hours', (select round(extract(epoch from avg(updated_at - created_at)) / 3600) from received where status in ('accepted','rejected')),
  -- Solo el día, para no revelar horarios exactos de conexión.
  'last_activity', (select greatest(
    (select max(created_at) from pubs),
    (select max(created_at) from public.offers where sender_id = target_user),
    (select max(created_at) from public.offer_messages where sender_id = target_user)
   )::date)
 )
 where exists (select 1 from public.profiles where id = target_user);
$$;
revoke all on function public.get_profile_stats(uuid) from public;
grant execute on function public.get_profile_stats(uuid) to anon, authenticated;
commit;
