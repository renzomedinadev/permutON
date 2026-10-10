-- Ejecutar una vez, después de migration-02.
begin;
alter table public.offers add column status text not null default 'pending'
 check (status in ('pending','accepted','rejected','cancelled'));
alter table public.offers add column updated_at timestamptz not null default now();

-- Los clientes solo pueden crear propuestas pendientes.
drop policy "send offer to another user" on public.offers;
create policy "send offer to another user" on public.offers for insert to authenticated
with check (sender_id = (select auth.uid()) and status = 'pending' and exists (
 select 1 from public.publications p where p.id = publication_id
 and p.status = 'active' and p.owner_id <> (select auth.uid())));

create or replace function public.list_my_offers()
returns table (offer jsonb, publication_title text, direction text)
language sql stable security definer set search_path = '' as $$
 select to_jsonb(o), p.title,
 case when o.sender_id = auth.uid() then 'sent' else 'received' end
 from public.offers o join public.publications p on p.id = o.publication_id
 where auth.uid() is not null and (o.sender_id = auth.uid() or p.owner_id = auth.uid())
 order by o.created_at desc;
$$;

create or replace function public.change_offer_status(offer_id uuid, new_status text)
returns text language plpgsql security definer set search_path = '' as $$
declare selected_offer public.offers; publication_owner uuid; publication_status text;
begin
 if auth.uid() is null then raise exception 'Ingresá a tu cuenta.'; end if;
 select * into selected_offer from public.offers where id = offer_id for update;
 if not found then raise exception 'La propuesta ya no existe.'; end if;
 select owner_id, status into publication_owner, publication_status
 from public.publications where id = selected_offer.publication_id;
 if not ((new_status in ('accepted','rejected') and publication_owner = auth.uid())
   or (new_status = 'cancelled' and selected_offer.sender_id = auth.uid())) then
   raise exception 'No tenés permiso para realizar esta acción.';
 end if;
 if selected_offer.status <> 'pending' then raise exception 'La propuesta ya fue resuelta. Actualizá la lista.'; end if;
 if new_status = 'accepted' and publication_status <> 'active' then
   raise exception 'La publicación ya no está activa.';
 end if;
 update public.offers set status = new_status, updated_at = now() where id = offer_id;
 return new_status;
end;
$$;
revoke all on function public.list_my_offers() from public, anon;
revoke all on function public.change_offer_status(uuid,text) from public, anon;
grant execute on function public.list_my_offers() to authenticated;
grant execute on function public.change_offer_status(uuid,text) to authenticated;
commit;
