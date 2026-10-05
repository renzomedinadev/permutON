-- Ejecutar una sola vez sobre la base que ya tiene schema.sql.
-- Conserva todas las publicaciones y propuestas existentes.
begin;

alter table public.publications add column if not exists photo_paths text[] not null default '{}';
update public.publications set photo_paths = array[photo_path]
where cardinality(photo_paths) = 0;
alter table public.publications add constraint publications_photo_paths_count
  check (cardinality(photo_paths) between 1 and 5);
alter table public.publications add constraint publications_primary_photo_matches
  check (photo_path = photo_paths[1]);

alter table public.offers add column if not exists title text;
alter table public.offers add column if not exists category text;
alter table public.offers add column if not exists description text;
alter table public.offers add column if not exists owned_time text;
alter table public.offers add column if not exists reason text;
alter table public.offers add column if not exists photo_paths text[] not null default '{}';

-- Las ofertas antiguas siguen siendo legibles; las nuevas tienen todos los detalles.
alter table public.offers add constraint offers_details_valid check (
  (title is null and category is null and description is null and owned_time is null and reason is null and cardinality(photo_paths) = 0)
  or
  (title is not null and category is not null and description is not null and owned_time is not null and reason is not null
   and char_length(title) between 1 and 70
   and category in ('Indumentaria','Tecnología','Hogar','Deportes','Libros','Otros')
   and char_length(description) between 1 and 500
   and char_length(owned_time) between 1 and 80
   and char_length(reason) between 1 and 300
   and cardinality(photo_paths) between 1 and 5)
);
commit;
