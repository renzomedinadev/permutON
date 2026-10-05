-- Ejecutar una sola vez en Supabase > SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.publications (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  owner_name text not null check (char_length(owner_name) between 1 and 50),
  title text not null check (char_length(title) between 1 and 70),
  category text not null check (category in ('Indumentaria','Tecnología','Hogar','Deportes','Libros','Otros')),
  description text not null check (char_length(description) between 1 and 500),
  owned_time text not null check (char_length(owned_time) between 1 and 80),
  reason text not null check (char_length(reason) between 1 and 300),
  wanted text not null check (char_length(wanted) between 1 and 100),
  photo_path text not null check (char_length(photo_path) between 1 and 300),
  status text not null default 'active' check (status in ('active','exchanged')),
  created_at timestamptz not null default now(),
  constraint photo_owned_by_user check (split_part(photo_path,'/',1) = owner_id::text)
);
create index if not exists publications_active_recent_idx on public.publications (created_at desc) where status = 'active';
create index if not exists publications_owner_idx on public.publications (owner_id);
create index if not exists publications_category_idx on public.publications (category, created_at desc) where status = 'active';
alter table public.publications enable row level security;
create policy "read active or owned publications" on public.publications for select to anon, authenticated using (status = 'active' or owner_id = (select auth.uid()));
create policy "create own publication" on public.publications for insert to authenticated with check (owner_id = (select auth.uid()) and status = 'active');
create policy "update own publication" on public.publications for update to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy "delete own publication" on public.publications for delete to authenticated using (owner_id = (select auth.uid()));

create table if not exists public.offers (
  id uuid primary key default gen_random_uuid(),
  publication_id uuid not null references public.publications(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  sender_name text not null check (char_length(sender_name) between 1 and 50),
  offered_item text not null check (char_length(offered_item) between 1 and 500),
  contact text not null check (char_length(contact) between 1 and 100),
  created_at timestamptz not null default now()
);
create index if not exists offers_publication_idx on public.offers (publication_id, created_at desc);
create index if not exists offers_sender_idx on public.offers (sender_id);
alter table public.offers enable row level security;
create policy "read offers as participant" on public.offers for select to authenticated using (sender_id = (select auth.uid()) or exists (select 1 from public.publications p where p.id = publication_id and p.owner_id = (select auth.uid())));
create policy "send offer to another user" on public.offers for insert to authenticated with check (sender_id = (select auth.uid()) and exists (select 1 from public.publications p where p.id = publication_id and p.status = 'active' and p.owner_id <> (select auth.uid())));

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('publication-photos','publication-photos',true,8388608,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 8388608, allowed_mime_types = array['image/jpeg','image/png','image/webp'];
create policy "upload photos into own folder" on storage.objects for insert to authenticated with check (bucket_id = 'publication-photos' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "delete photos from own folder" on storage.objects for delete to authenticated using (bucket_id = 'publication-photos' and (storage.foldername(name))[1] = (select auth.uid())::text);
