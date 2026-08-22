create extension if not exists pgcrypto;
create extension if not exists pgtap with schema extensions;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  phone text not null,
  full_name text,
  avatar_url text,
  gender text check (gender in ('male','female')),
  role text not null check (role in ('customer','barber')),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);

create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, phone, role)
  values (
    new.id,
    coalesce(new.phone, ''),
    coalesce(new.raw_user_meta_data->>'role', 'customer')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create table public.user_consents (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  consent_type text not null check (consent_type in ('data_processing','ktp_verification')),
  terms_version text not null,
  granted_at timestamptz not null default now()
);

alter table public.user_consents enable row level security;

create policy "user_consents_select_own" on public.user_consents
  for select using (auth.uid() = profile_id);

create policy "user_consents_insert_own" on public.user_consents
  for insert with check (auth.uid() = profile_id);

create table public.addresses (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  label text not null,
  provinsi text not null,
  kota text not null,
  kecamatan text not null,
  kelurahan text not null,
  detail text not null,
  lat double precision,
  lng double precision,
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.addresses enable row level security;

create policy "addresses_select_own" on public.addresses
  for select using (auth.uid() = profile_id);

create policy "addresses_insert_own" on public.addresses
  for insert with check (auth.uid() = profile_id);

create policy "addresses_update_own" on public.addresses
  for update using (auth.uid() = profile_id) with check (auth.uid() = profile_id);

create policy "addresses_delete_own" on public.addresses
  for delete using (auth.uid() = profile_id);

grant select on public.profiles to authenticated;
revoke update on public.profiles from authenticated;
grant update (full_name, avatar_url, gender) on public.profiles to authenticated;
grant select, insert on public.user_consents to authenticated;
grant select, insert, update, delete on public.addresses to authenticated;
