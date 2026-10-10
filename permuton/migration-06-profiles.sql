-- Ejecutar una vez después de migration-05.
-- Crea un perfil por usuario y hace que el nombre visible salga del perfil,
-- no de lo que se escribe en cada publicación o propuesta.
begin;

create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 display_name text not null check (char_length(trim(display_name)) between 2 and 40),
 bio text check (bio is null or char_length(bio) <= 300),
 province_id text,
 locality_id text,
 avatar_path text check (avatar_path is null or (char_length(avatar_path) <= 300 and split_part(avatar_path,'/',1) = id::text)),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint profile_location_pair check ((province_id is null and locality_id is null) or (province_id is not null and locality_id is not null)),
 constraint profile_argentina_locality foreign key (locality_id,province_id) references public.argentina_localities(id,province_id)
);
alter table public.profiles enable row level security;
create policy "public profiles" on public.profiles for select to anon,authenticated using (true);
create policy "create own profile" on public.profiles for insert to authenticated with check (id = (select auth.uid()));
create policy "update own profile" on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));
-- El navegador solo puede tocar los campos editables; fechas e id los maneja la base.
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to anon, authenticated;
grant insert (id,display_name,bio,province_id,locality_id,avatar_path) on public.profiles to authenticated;
grant update (display_name,bio,province_id,locality_id,avatar_path) on public.profiles to authenticated;

create or replace function public.default_display_name(user_id uuid, wanted text)
returns text language sql immutable set search_path = '' as $$
 select case when char_length(trim(coalesce(wanted,''))) between 2 and 40 then trim(wanted)
 else 'Usuario ' || substr(user_id::text,1,6) end;
$$;

-- Perfil automático al registrarse (toma el nombre enviado en el registro).
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
 insert into public.profiles (id, display_name)
 values (NEW.id, public.default_display_name(NEW.id, NEW.raw_user_meta_data->>'display_name'))
 on conflict (id) do nothing;
 return NEW;
end;
$$;
create trigger on_auth_user_created after insert on auth.users
 for each row execute function public.handle_new_user();

-- Perfiles para los usuarios existentes: último nombre usado en publicaciones o propuestas.
insert into public.profiles (id, display_name, created_at)
select u.id,
 public.default_display_name(u.id, left(coalesce(
  (select p.owner_name from public.publications p where p.owner_id = u.id order by p.created_at desc limit 1),
  (select o.sender_name from public.offers o where o.sender_id = u.id order by o.created_at desc limit 1)
 ), 40)),
 u.created_at
from auth.users u
on conflict (id) do nothing;

create or replace function public.touch_profile()
returns trigger language plpgsql set search_path = '' as $$
begin NEW.display_name := trim(NEW.display_name); NEW.updated_at := now(); return NEW; end;
$$;
create trigger touch_profile before update on public.profiles
 for each row execute function public.touch_profile();

-- El nombre de publicaciones y propuestas siempre es el del perfil.
create or replace function public.set_publication_owner_name()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
 NEW.owner_name := coalesce((select display_name from public.profiles where id = NEW.owner_id), NEW.owner_name);
 return NEW;
end;
$$;
create trigger set_publication_owner_name before insert or update on public.publications
 for each row execute function public.set_publication_owner_name();

create or replace function public.set_offer_sender_name()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
 NEW.sender_name := coalesce((select display_name from public.profiles where id = NEW.sender_id), NEW.sender_name);
 return NEW;
end;
$$;
create trigger set_offer_sender_name before insert on public.offers
 for each row execute function public.set_offer_sender_name();

-- Al cambiar el nombre del perfil se actualiza en todo lo publicado.
create or replace function public.propagate_display_name()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
 update public.publications set owner_name = NEW.display_name where owner_id = NEW.id and owner_name <> NEW.display_name;
 update public.offers set sender_name = NEW.display_name where sender_id = NEW.id and sender_name <> NEW.display_name;
 return NEW;
end;
$$;
create trigger propagate_display_name after update of display_name on public.profiles
 for each row when (OLD.display_name is distinct from NEW.display_name)
 execute function public.propagate_display_name();

-- Unificar los nombres ya guardados con el del perfil.
update public.publications p set owner_name = pr.display_name from public.profiles pr where pr.id = p.owner_id and p.owner_name <> pr.display_name;
update public.offers o set sender_name = pr.display_name from public.profiles pr where pr.id = o.sender_id and o.sender_name <> pr.display_name;

revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.set_publication_owner_name() from public, anon, authenticated;
revoke all on function public.set_offer_sender_name() from public, anon, authenticated;
revoke all on function public.propagate_display_name() from public, anon, authenticated;
commit;
