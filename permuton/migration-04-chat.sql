-- Ejecutar una vez después de migration-03.
begin;
create table public.offer_messages (
 id uuid primary key default gen_random_uuid(),
 offer_id uuid not null references public.offers(id) on delete cascade,
 sender_id uuid not null references auth.users(id) on delete cascade,
 body text not null check (char_length(trim(body)) between 1 and 2000),
 created_at timestamptz not null default now()
);
create index offer_messages_recent_idx on public.offer_messages (offer_id, created_at desc, id desc);
alter table public.offer_messages enable row level security;

create or replace function public.can_access_offer_chat(target_offer uuid, sending boolean default false)
returns boolean language sql stable security definer set search_path = '' as $$
 select exists (
 select 1 from public.offers o join public.publications p on p.id = o.publication_id
 where o.id = target_offer and auth.uid() is not null
 and (o.sender_id = auth.uid() or p.owner_id = auth.uid())
 and (not sending or o.status in ('pending','accepted'))
 );
$$;
revoke all on function public.can_access_offer_chat(uuid,boolean) from public, anon;
grant execute on function public.can_access_offer_chat(uuid,boolean) to authenticated;
create policy "chat participants read messages" on public.offer_messages for select to authenticated
 using (public.can_access_offer_chat(offer_id,false));
create policy "chat participants send messages" on public.offer_messages for insert to authenticated
 with check (sender_id = (select auth.uid()) and public.can_access_offer_chat(offer_id,true));
-- No se permiten editar o borrar mensajes desde el navegador.
grant select, insert on public.offer_messages to authenticated;
revoke all on public.offer_messages from anon;
commit;
