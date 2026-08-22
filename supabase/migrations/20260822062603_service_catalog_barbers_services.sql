create table public.service_catalog (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  icon text,
  category text,
  is_active boolean not null default true
);

alter table public.service_catalog enable row level security;

create policy "service_catalog_select_all" on public.service_catalog
  for select using (true);

-- RLS policies alone don't grant access on this project: config.toml's
-- auto_expose_new_tables is unset (the current default), so a role needs an
-- explicit base-table GRANT before its RLS policies get a chance to apply.
grant select on public.service_catalog to anon, authenticated;

create table public.barbers (
  id uuid primary key references public.profiles(id) on delete cascade,
  nik text,
  ktp_photo_url text,
  selfie_photo_url text,
  verification_status text not null default 'pending' check (verification_status in ('pending','verified','rejected')),
  mode_muslimah_status text not null default 'none' check (mode_muslimah_status in ('none','verified')),
  rating_avg numeric(3,2) not null default 0,
  rating_count integer not null default 0,
  vehicle_desc text,
  credit_balance_cents integer not null default 0,
  created_at timestamptz not null default now()
);

alter table public.barbers enable row level security;

create policy "barbers_select_own" on public.barbers
  for select using (auth.uid() = id);

create policy "barbers_update_own" on public.barbers
  for update using (auth.uid() = id) with check (auth.uid() = id);

grant select on public.barbers to authenticated;

-- RLS makes the row visible for UPDATE, but only these columns are actually
-- writable by the barber — verification_status/mode_muslimah_status/credit_balance_cents
-- stay server-only even though the row-level policy would otherwise allow the write.
revoke update on public.barbers from authenticated;
grant update (nik, ktp_photo_url, selfie_photo_url, vehicle_desc) on public.barbers to authenticated;

-- Public browsing surface: exposes only verification-safe columns for verified
-- barbers. This view runs as its owner (bypassing the owner-only RLS above by
-- design), so its column list is the only thing keeping NIK/KTP/selfie private.
create view public.barbers_public as
select id, rating_avg, rating_count, vehicle_desc, mode_muslimah_status
from public.barbers
where verification_status = 'verified';

grant select on public.barbers_public to anon, authenticated;

-- extend the Task 1 trigger so a 'barber' signup also gets a stub barbers row
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text := coalesce(new.raw_user_meta_data->>'role', 'customer');
begin
  insert into public.profiles (id, phone, role)
  values (new.id, coalesce(new.phone, ''), v_role);

  if v_role = 'barber' then
    insert into public.barbers (id) values (new.id);
  end if;

  return new;
end;
$$;

create table public.services (
  id uuid primary key default gen_random_uuid(),
  barber_id uuid not null references public.barbers(id) on delete cascade,
  catalog_service_id uuid not null references public.service_catalog(id),
  price_cents integer not null check (price_cents >= 0),
  duration_minutes integer not null check (duration_minutes > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (barber_id, catalog_service_id)
);

alter table public.services enable row level security;

create policy "services_select_all" on public.services
  for select using (true);

create policy "services_write_own" on public.services
  for all using (auth.uid() = barber_id) with check (auth.uid() = barber_id);

grant select on public.services to anon, authenticated;
grant insert, update, delete on public.services to authenticated;

create table public.barber_service_areas (
  barber_id uuid not null references public.barbers(id) on delete cascade,
  kelurahan text not null,
  primary key (barber_id, kelurahan)
);

alter table public.barber_service_areas enable row level security;

create policy "areas_select_all" on public.barber_service_areas
  for select using (true);

create policy "areas_write_own" on public.barber_service_areas
  for all using (auth.uid() = barber_id) with check (auth.uid() = barber_id);

grant select on public.barber_service_areas to anon, authenticated;
grant insert, update, delete on public.barber_service_areas to authenticated;
