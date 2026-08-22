# Cukur Supabase Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the full Cukur MVP Postgres schema (profiles, addresses, barbers, service catalog, bookings, ratings, wallet ledger, consents) with RLS, plus the Xendit-backed QRIS wallet top-up flow (create + webhook), in `supabase/`.

**Architecture:** Numbered SQL migrations build the schema incrementally, each with RLS policies co-located in the same migration and a pgTAP test file proving the schema shape and access rules. All privileged writes (booking status transitions, wallet ledger entries) go through `SECURITY DEFINER` Postgres functions, not raw client `UPDATE`/`INSERT`, so the RLS surface stays narrow. Two Deno edge functions handle the Xendit side: `wallet-topup-create` (barber-initiated, creates a Xendit QR payment request) and `xendit-webhook` (Xendit-initiated, credits the wallet on payment success).

**Tech Stack:** Supabase CLI (`npx supabase@latest`), Postgres 17, pgTAP for database tests (`npx supabase test db`), Deno 2 edge functions (`npx supabase functions serve`), Xendit Payment Requests API (QR_CODE / QRIS, test mode).

**Spec:** `docs/superpowers/specs/2026-08-22-supabase-backend-design.md`

## Global Constraints

- Money is always integer cents in columns suffixed `_cents` (matches spec).
- App fee is a flat 5% of `bookings.price_cents`, computed server-side in `fn_complete_booking` — never client-supplied.
- No table gets a client-facing `UPDATE`/`INSERT` policy where the spec says writes go "through the functions" — `bookings` (status columns), `booking_ratings`, `wallet_transactions` all rely on `SECURITY DEFINER` functions instead.
- Every `SECURITY DEFINER` function sets `set search_path = public, pg_temp` (prevents search-path hijacking) and does its own `auth.uid()` authorization check before touching data.
- `service_catalog` has no client write path at all in this pass (seeded via migration).
- Xendit integration targets **test/sandbox mode only** — `XENDIT_SECRET_KEY` and `XENDIT_WEBHOOK_TOKEN` are set from the user's existing sandbox keys via `npx supabase secrets set`.
- Xendit's own docs disagree with each other on the exact Payment Requests response/webhook field names across product generations (verified during design research — see spec's Open Items). Code that parses Xendit responses is written defensively (multiple known field paths) and the raw payload is always persisted to `wallet_transactions.xendit_raw_response` so nothing is lost if a field name turns out wrong — Task 8 is a real sandbox smoke test that will surface any mismatch before this ships.

---

## File Structure

```
supabase/
  migrations/
    <ts>_profiles_consents_addresses.sql
    <ts>_service_catalog_barbers_services.sql
    <ts>_bookings_ratings.sql
    <ts>_wallet_ledger.sql
    <ts>_booking_service_details_fn.sql
  seed.sql                                    -- modified: service_catalog rows
  tests/database/
    profiles_consents_addresses.test.sql
    service_catalog_barbers_services.test.sql
    bookings_ratings.test.sql
    wallet_ledger.test.sql
    booking_service_details_fn.test.sql
  functions/
    wallet-topup-create/
      extract_qr_details.ts                   -- pure fn: parse Xendit's create-response
      extract_qr_details.test.ts
      index.ts                                -- HTTP handler
    xendit-webhook/
      verify_token.ts                         -- pure fn: constant-time token compare
      verify_token.test.ts
      parse_event.ts                          -- pure fn: parse Xendit's webhook payload
      parse_event.test.ts
      index.ts                                -- HTTP handler
  config.toml                                 -- modified: verify_jwt = false for xendit-webhook
```

---

### Task 1: profiles, user_consents, addresses

**Files:**
- Create: `supabase/migrations/<ts>_profiles_consents_addresses.sql` (via `npx supabase migration new profiles_consents_addresses`)
- Test: `supabase/tests/database/profiles_consents_addresses.test.sql`

**Interfaces:**
- Produces: `public.profiles(id, phone, full_name, avatar_url, gender, role, created_at)`, `public.user_consents(id, profile_id, consent_type, terms_version, granted_at)`, `public.addresses(id, profile_id, label, provinsi, kota, kecamatan, kelurahan, detail, lat, lng, is_default, created_at)`, trigger function `public.handle_new_user()` (extended in Task 2), `extensions.pgtap` enabled for all later tasks.

- [ ] **Step 1: Create the migration file**

Run: `npx supabase migration new profiles_consents_addresses`

This creates `supabase/migrations/<timestamp>_profiles_consents_addresses.sql`. Use that exact filename for the rest of this task.

- [ ] **Step 2: Write the migration**

```sql
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
```

- [ ] **Step 3: Write the failing pgTAP test**

Create `supabase/tests/database/profiles_consents_addresses.test.sql`:

```sql
begin;
select plan(6);

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'cust@test.dev'),
  ('22222222-2222-2222-2222-222222222222', 'barb@test.dev');

select has_table('public', 'profiles', 'profiles table exists');
select has_table('public', 'addresses', 'addresses table exists');
select has_table('public', 'user_consents', 'user_consents table exists');

select results_eq(
  $$ select role from public.profiles where id = '11111111-1111-1111-1111-111111111111' $$,
  $$ values ('customer'::text) $$,
  'handle_new_user defaults role to customer'
);

set local role authenticated;
set local "request.jwt.claims" to '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select is_empty(
  $$ select 1 from public.profiles where id = '22222222-2222-2222-2222-222222222222' $$,
  'a user cannot select another profile'
);

insert into public.addresses (profile_id, label, provinsi, kota, kecamatan, kelurahan, detail)
values ('11111111-1111-1111-1111-111111111111', 'Rumah', 'DKI Jakarta', 'Jakarta Selatan', 'Kebayoran Baru', 'Senayan', 'Jl. Test No. 1');

select results_eq(
  $$ select count(*)::int from public.addresses where profile_id = '11111111-1111-1111-1111-111111111111' $$,
  $$ values (1) $$,
  'a user can insert their own address'
);

select * from finish();
rollback;
```

- [ ] **Step 4: Run the test and confirm it fails**

Run: `npx supabase db reset` then `npx supabase test db`
Expected: FAIL — the migration file is empty at this point if you're following strict TDD; since Step 2 already wrote the migration, instead run `npx supabase test db` before Step 2 to see the true RED state, or trust that `has_table` assertions would fail against an empty schema. Either order is fine here — the meaningful gate is Step 5's green run.

- [ ] **Step 5: Run the test and confirm it passes**

Run: `npx supabase db reset && npx supabase test db`
Expected: all 6 assertions pass (`# Looks like you passed 6 tests`)

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations supabase/tests/database/profiles_consents_addresses.test.sql
git commit -m "feat: add profiles, user_consents, addresses schema with RLS"
```

---

### Task 2: service_catalog, barbers, services, barber_service_areas

**Files:**
- Create: `supabase/migrations/<ts>_service_catalog_barbers_services.sql`
- Modify: `supabase/seed.sql`
- Test: `supabase/tests/database/service_catalog_barbers_services.test.sql`

**Interfaces:**
- Consumes: `public.profiles`, `public.handle_new_user()` from Task 1
- Produces: `public.service_catalog(id, name, description, icon, category, is_active)`, `public.barbers(id, nik, ktp_photo_url, selfie_photo_url, verification_status, mode_muslimah_status, rating_avg, rating_count, vehicle_desc, credit_balance_cents, created_at)`, `public.barbers_public` view (id, rating_avg, rating_count, vehicle_desc, mode_muslimah_status), `public.services(id, barber_id, catalog_service_id, price_cents, duration_minutes, is_active, created_at)`, `public.barber_service_areas(barber_id, kelurahan)`

- [ ] **Step 1: Create the migration file**

Run: `npx supabase migration new service_catalog_barbers_services`

- [ ] **Step 2: Write the migration**

```sql
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
```

- [ ] **Step 3: Add seed data**

Append to `supabase/seed.sql` (create the file with this content if it doesn't exist yet):

```sql
insert into public.service_catalog (name, description, category) values
  ('Potong rambut pria', 'Potong rambut standar untuk pria dewasa', 'haircut'),
  ('Potong rambut anak', 'Potong rambut untuk anak di bawah 12 tahun', 'haircut'),
  ('Cukur jenggot & kumis', 'Perapian jenggot dan kumis', 'grooming'),
  ('Keramas & styling', 'Cuci rambut plus styling', 'grooming'),
  ('Pewarnaan rambut', 'Pewarnaan rambut sederhana', 'coloring');
```

- [ ] **Step 4: Write the failing pgTAP test**

Create `supabase/tests/database/service_catalog_barbers_services.test.sql`:

```sql
begin;
select plan(6);

insert into auth.users (id, email, raw_user_meta_data) values
  ('33333333-3333-3333-3333-333333333333', 'barber1@test.dev', '{"role":"barber"}'),
  ('44444444-4444-4444-4444-444444444444', 'barber2@test.dev', '{"role":"barber"}');

select has_table('public', 'barbers', 'barbers table exists');
select has_table('public', 'services', 'services table exists');

select results_eq(
  $$ select verification_status from public.barbers where id = '33333333-3333-3333-3333-333333333333' $$,
  $$ values ('pending'::text) $$,
  'barber signup gets a stub barbers row via the trigger'
);

update public.barbers set verification_status = 'verified' where id = '33333333-3333-3333-3333-333333333333';

select is_empty(
  $$ select 1 from public.barbers_public where id = '44444444-4444-4444-4444-444444444444' $$,
  'unverified barber is not exposed via barbers_public'
);

select results_eq(
  $$ select count(*)::int from public.barbers_public where id = '33333333-3333-3333-3333-333333333333' $$,
  $$ values (1) $$,
  'verified barber is exposed via barbers_public'
);

set local role authenticated;
set local "request.jwt.claims" to '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';

select throws_ok(
  $$ update public.barbers set verification_status = 'rejected' where id = '33333333-3333-3333-3333-333333333333' $$,
  'permission denied for column verification_status',
  'a barber cannot self-write verification_status'
);

select * from finish();
rollback;
```

- [ ] **Step 5: Run the test and confirm it fails, then implement, then confirm it passes**

Run: `npx supabase db reset && npx supabase test db`
Expected before Step 2's migration is written: FAIL (`barbers` table missing). After: all 6 assertions pass. Note the exact error text `throws_ok` expects can vary by Postgres version — if it doesn't match, run the failing UPDATE by hand via `npx supabase db reset` + `psql` to read Postgres's actual error text and adjust the test's expected string.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations supabase/seed.sql supabase/tests/database/service_catalog_barbers_services.test.sql
git commit -m "feat: add service catalog, barbers, services, service areas schema"
```

---

### Task 3: bookings, booking_ratings, status-transition functions

**Files:**
- Create: `supabase/migrations/<ts>_bookings_ratings.sql`
- Test: `supabase/tests/database/bookings_ratings.test.sql`

**Interfaces:**
- Consumes: `public.profiles`, `public.barbers`, `public.services`, `public.addresses`
- Produces: `public.bookings(id, customer_id, barber_id, service_id, address_id, notes, status, price_cents, app_fee_cents, scheduled_at, accepted_at, en_route_at, arrived_at, started_at, completed_at, paid_confirmed_at, cancelled_at, created_at)`, `public.booking_ratings(booking_id, customer_id, barber_id, stars, comment, created_at)`, `public.fn_transition_booking(p_booking_id uuid, p_new_status text) returns public.bookings`, `public.fn_submit_rating(p_booking_id uuid, p_stars integer, p_comment text) returns public.booking_ratings`

- [ ] **Step 1: Create the migration file**

Run: `npx supabase migration new bookings_ratings`

- [ ] **Step 2: Write the migration**

```sql
create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.profiles(id),
  barber_id uuid not null references public.barbers(id),
  service_id uuid not null references public.services(id),
  address_id uuid not null references public.addresses(id),
  notes text,
  status text not null default 'requested' check (status in
    ('requested','accepted','declined','en_route','arrived','in_progress','completed','cancelled','paid_confirmed','rated')),
  price_cents integer not null check (price_cents >= 0),
  app_fee_cents integer,
  scheduled_at timestamptz,
  accepted_at timestamptz,
  en_route_at timestamptz,
  arrived_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  paid_confirmed_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.bookings enable row level security;

create policy "bookings_select_party" on public.bookings
  for select using (auth.uid() = customer_id or auth.uid() = barber_id);

create policy "bookings_insert_customer" on public.bookings
  for insert with check (auth.uid() = customer_id);

create or replace function public.fn_transition_booking(p_booking_id uuid, p_new_status text)
returns public.bookings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_booking public.bookings;
  v_caller uuid := auth.uid();
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null then
    raise exception 'booking not found';
  end if;

  if p_new_status = 'accepted' then
    if v_caller <> v_booking.barber_id or v_booking.status <> 'requested' then
      raise exception 'not allowed';
    end if;
    update public.bookings set status = 'accepted', accepted_at = now() where id = p_booking_id returning * into v_booking;

  elsif p_new_status = 'declined' then
    if v_caller <> v_booking.barber_id or v_booking.status <> 'requested' then
      raise exception 'not allowed';
    end if;
    update public.bookings set status = 'declined' where id = p_booking_id returning * into v_booking;

  elsif p_new_status = 'en_route' then
    if v_caller <> v_booking.barber_id or v_booking.status <> 'accepted' then
      raise exception 'not allowed';
    end if;
    update public.bookings set status = 'en_route', en_route_at = now() where id = p_booking_id returning * into v_booking;

  elsif p_new_status = 'arrived' then
    if v_caller <> v_booking.barber_id or v_booking.status <> 'en_route' then
      raise exception 'not allowed';
    end if;
    update public.bookings set status = 'arrived', arrived_at = now() where id = p_booking_id returning * into v_booking;

  elsif p_new_status = 'in_progress' then
    if v_caller <> v_booking.barber_id or v_booking.status <> 'arrived' then
      raise exception 'not allowed';
    end if;
    update public.bookings set status = 'in_progress', started_at = now() where id = p_booking_id returning * into v_booking;

  elsif p_new_status = 'cancelled' then
    if v_caller not in (v_booking.customer_id, v_booking.barber_id)
       or v_booking.status in ('in_progress','completed','cancelled','paid_confirmed','rated') then
      raise exception 'not allowed';
    end if;
    update public.bookings set status = 'cancelled', cancelled_at = now() where id = p_booking_id returning * into v_booking;

  elsif p_new_status = 'paid_confirmed' then
    if v_caller <> v_booking.barber_id or v_booking.status <> 'completed' then
      raise exception 'not allowed';
    end if;
    update public.bookings set status = 'paid_confirmed', paid_confirmed_at = now() where id = p_booking_id returning * into v_booking;

  else
    raise exception 'unsupported or unreachable status: %', p_new_status;
  end if;

  return v_booking;
end;
$$;

revoke all on function public.fn_transition_booking(uuid, text) from public;
grant execute on function public.fn_transition_booking(uuid, text) to authenticated;

create table public.booking_ratings (
  booking_id uuid primary key references public.bookings(id),
  customer_id uuid not null references public.profiles(id),
  barber_id uuid not null references public.barbers(id),
  stars integer not null check (stars between 1 and 5),
  comment text,
  created_at timestamptz not null default now()
);

alter table public.booking_ratings enable row level security;

create policy "ratings_select_party" on public.booking_ratings
  for select using (auth.uid() = customer_id or auth.uid() = barber_id);

create or replace function public.fn_submit_rating(p_booking_id uuid, p_stars integer, p_comment text)
returns public.booking_ratings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_booking public.bookings;
  v_rating public.booking_ratings;
begin
  if p_stars < 1 or p_stars > 5 then
    raise exception 'stars must be between 1 and 5';
  end if;

  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null or v_booking.customer_id <> auth.uid() or v_booking.status <> 'paid_confirmed' then
    raise exception 'not allowed';
  end if;

  insert into public.booking_ratings (booking_id, customer_id, barber_id, stars, comment)
  values (p_booking_id, v_booking.customer_id, v_booking.barber_id, p_stars, p_comment)
  returning * into v_rating;

  update public.bookings set status = 'rated' where id = p_booking_id;

  update public.barbers
  set rating_count = rating_count + 1,
      rating_avg = round(((rating_avg * rating_count) + p_stars) / (rating_count + 1), 2)
  where id = v_booking.barber_id;

  return v_rating;
end;
$$;

revoke all on function public.fn_submit_rating(uuid, integer, text) from public;
grant execute on function public.fn_submit_rating(uuid, integer, text) to authenticated;
```

- [ ] **Step 3: Write the failing pgTAP test**

Create `supabase/tests/database/bookings_ratings.test.sql`:

```sql
begin;
select plan(5);

insert into auth.users (id, email, raw_user_meta_data) values
  ('55555555-5555-5555-5555-555555555555', 'cust3@test.dev', '{"role":"customer"}'),
  ('66666666-6666-6666-6666-666666666666', 'barb3@test.dev', '{"role":"barber"}');

update public.barbers set verification_status = 'verified' where id = '66666666-6666-6666-6666-666666666666';

insert into public.addresses (id, profile_id, label, provinsi, kota, kecamatan, kelurahan, detail)
values ('77777777-7777-7777-7777-777777777777', '55555555-5555-5555-5555-555555555555', 'Rumah', 'DKI Jakarta', 'Jakarta Selatan', 'Kebayoran Baru', 'Senayan', 'Jl. Test No. 2');

insert into public.services (id, barber_id, catalog_service_id, price_cents, duration_minutes)
select '88888888-8888-8888-8888-888888888888', '66666666-6666-6666-6666-666666666666', id, 5000000, 45
from public.service_catalog limit 1;

insert into public.bookings (id, customer_id, barber_id, service_id, address_id, price_cents)
values ('99999999-9999-9999-9999-999999999999', '55555555-5555-5555-5555-555555555555', '66666666-6666-6666-6666-666666666666', '88888888-8888-8888-8888-888888888888', '77777777-7777-7777-7777-777777777777', 5000000);

select has_table('public', 'bookings', 'bookings table exists');

set local role authenticated;
set local "request.jwt.claims" to '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}';

select throws_ok(
  $$ select public.fn_transition_booking('99999999-9999-9999-9999-999999999999', 'accepted') $$,
  'not allowed',
  'customer cannot accept their own booking'
);

reset role;
set local role authenticated;
set local "request.jwt.claims" to '{"sub":"66666666-6666-6666-6666-666666666666","role":"authenticated"}';

select lives_ok(
  $$ select public.fn_transition_booking('99999999-9999-9999-9999-999999999999', 'accepted') $$,
  'barber can accept a requested booking'
);

select results_eq(
  $$ select status from public.bookings where id = '99999999-9999-9999-9999-999999999999' $$,
  $$ values ('accepted'::text) $$,
  'booking status updated to accepted'
);

select throws_ok(
  $$ select public.fn_transition_booking('99999999-9999-9999-9999-999999999999', 'in_progress') $$,
  'not allowed',
  'cannot skip from accepted straight to in_progress'
);

select * from finish();
rollback;
```

- [ ] **Step 4: Run the test, confirm it fails then passes**

Run: `npx supabase db reset && npx supabase test db`
Expected: 5/5 pass once the migration is in place.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations supabase/tests/database/bookings_ratings.test.sql
git commit -m "feat: add bookings, booking_ratings, status-transition functions"
```

---

### Task 4: wallet_transactions ledger + fee/top-up functions

**Files:**
- Create: `supabase/migrations/<ts>_wallet_ledger.sql`
- Test: `supabase/tests/database/wallet_ledger.test.sql`

**Interfaces:**
- Consumes: `public.barbers`, `public.bookings`
- Produces: `public.wallet_transactions(id, barber_id, type, amount_cents, balance_after_cents, booking_id, xendit_payment_request_id, xendit_qr_string, xendit_raw_response, expires_at, status, created_at, settled_at)`, `public.fn_complete_booking(p_booking_id uuid) returns public.bookings`, `public.fn_credit_topup(p_transaction_id uuid) returns public.wallet_transactions` (service_role only — this is the function `xendit-webhook` (Task 7) calls by name via RPC)

- [ ] **Step 1: Create the migration file**

Run: `npx supabase migration new wallet_ledger`

- [ ] **Step 2: Write the migration**

```sql
create table public.wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  barber_id uuid not null references public.barbers(id),
  type text not null check (type in ('topup','fee')),
  amount_cents integer not null,
  balance_after_cents integer,
  booking_id uuid references public.bookings(id),
  xendit_payment_request_id text,
  xendit_qr_string text,
  xendit_raw_response jsonb,
  expires_at timestamptz,
  status text not null default 'pending' check (status in ('pending','succeeded','expired','failed')),
  created_at timestamptz not null default now(),
  settled_at timestamptz
);

alter table public.wallet_transactions enable row level security;

create policy "wallet_tx_select_own" on public.wallet_transactions
  for select using (auth.uid() = barber_id);

create or replace function public.fn_complete_booking(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_booking public.bookings;
  v_fee integer;
  v_new_balance integer;
begin
  select * into v_booking from public.bookings where id = p_booking_id for update;
  if v_booking.id is null or v_booking.barber_id <> auth.uid() or v_booking.status <> 'in_progress' then
    raise exception 'not allowed';
  end if;

  v_fee := round(v_booking.price_cents * 0.05);

  if (select credit_balance_cents from public.barbers where id = v_booking.barber_id) < v_fee then
    raise exception 'insufficient credit balance for the app fee';
  end if;

  update public.barbers
  set credit_balance_cents = credit_balance_cents - v_fee
  where id = v_booking.barber_id
  returning credit_balance_cents into v_new_balance;

  insert into public.wallet_transactions (barber_id, type, amount_cents, balance_after_cents, booking_id, status, settled_at)
  values (v_booking.barber_id, 'fee', -v_fee, v_new_balance, p_booking_id, 'succeeded', now());

  update public.bookings
  set status = 'completed', completed_at = now(), app_fee_cents = v_fee
  where id = p_booking_id
  returning * into v_booking;

  return v_booking;
end;
$$;

revoke all on function public.fn_complete_booking(uuid) from public;
grant execute on function public.fn_complete_booking(uuid) to authenticated;

create or replace function public.fn_credit_topup(p_transaction_id uuid)
returns public.wallet_transactions
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_tx public.wallet_transactions;
  v_new_balance integer;
begin
  select * into v_tx from public.wallet_transactions where id = p_transaction_id for update;
  if v_tx.id is null then
    raise exception 'transaction not found';
  end if;
  if v_tx.status <> 'pending' then
    return v_tx;
  end if;

  update public.barbers
  set credit_balance_cents = credit_balance_cents + v_tx.amount_cents
  where id = v_tx.barber_id
  returning credit_balance_cents into v_new_balance;

  update public.wallet_transactions
  set status = 'succeeded', balance_after_cents = v_new_balance, settled_at = now()
  where id = p_transaction_id
  returning * into v_tx;

  return v_tx;
end;
$$;

revoke all on function public.fn_credit_topup(uuid) from public, authenticated, anon;
grant execute on function public.fn_credit_topup(uuid) to service_role;
```

- [ ] **Step 3: Write the failing pgTAP test**

Create `supabase/tests/database/wallet_ledger.test.sql`:

```sql
begin;
select plan(5);

insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaaaaaa-1111-1111-1111-111111111111', 'cust4@test.dev', '{"role":"customer"}'),
  ('bbbbbbbb-1111-1111-1111-111111111111', 'barb4@test.dev', '{"role":"barber"}');

update public.barbers set verification_status = 'verified', credit_balance_cents = 1000000
where id = 'bbbbbbbb-1111-1111-1111-111111111111';

insert into public.addresses (id, profile_id, label, provinsi, kota, kecamatan, kelurahan, detail)
values ('cccccccc-1111-1111-1111-111111111111', 'aaaaaaaa-1111-1111-1111-111111111111', 'Rumah', 'DKI Jakarta', 'Jakarta Selatan', 'Kebayoran Baru', 'Senayan', 'Jl. Test No. 3');

insert into public.services (id, barber_id, catalog_service_id, price_cents, duration_minutes)
select 'dddddddd-1111-1111-1111-111111111111', 'bbbbbbbb-1111-1111-1111-111111111111', id, 8500000, 45
from public.service_catalog limit 1;

insert into public.bookings (id, customer_id, barber_id, service_id, address_id, price_cents, status)
values ('eeeeeeee-1111-1111-1111-111111111111', 'aaaaaaaa-1111-1111-1111-111111111111', 'bbbbbbbb-1111-1111-1111-111111111111', 'dddddddd-1111-1111-1111-111111111111', 'cccccccc-1111-1111-1111-111111111111', 8500000, 'in_progress');

select has_table('public', 'wallet_transactions', 'wallet_transactions table exists');

set local role authenticated;
set local "request.jwt.claims" to '{"sub":"bbbbbbbb-1111-1111-1111-111111111111","role":"authenticated"}';

select lives_ok(
  $$ select public.fn_complete_booking('eeeeeeee-1111-1111-1111-111111111111') $$,
  'barber can complete an in-progress booking'
);

select results_eq(
  $$ select credit_balance_cents from public.barbers where id = 'bbbbbbbb-1111-1111-1111-111111111111' $$,
  $$ values (575000) $$,
  'flat 5%% fee (8500000 * 0.05 = 425000) deducted from the 1000000 starting balance'
);

select results_eq(
  $$ select count(*)::int from public.wallet_transactions where barber_id = 'bbbbbbbb-1111-1111-1111-111111111111' and type = 'fee' $$,
  $$ values (1) $$,
  'a fee ledger row was written'
);

reset role;

insert into public.wallet_transactions (id, barber_id, type, amount_cents, status)
values ('ffffffff-1111-1111-1111-111111111111', 'bbbbbbbb-1111-1111-1111-111111111111', 'topup', 250000, 'pending');

select lives_ok(
  $$ select public.fn_credit_topup('ffffffff-1111-1111-1111-111111111111') $$,
  'fn_credit_topup runs for service_role'
);

select * from finish();
rollback;
```

Note: work out the exact expected `credit_balance_cents` value by hand before running (`1000000 - round(8500000 * 0.05)`) and fix the literal in the test if the arithmetic above is wrong — don't trust the comment, trust the computation.

- [ ] **Step 4: Run the test, confirm it fails then passes**

Run: `npx supabase db reset && npx supabase test db`
Expected: 5/5 pass. If the balance assertion fails, recompute `round(price_cents * 0.05)` and fix the expected literal — this is exactly the kind of arithmetic mistake TDD is meant to catch.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations supabase/tests/database/wallet_ledger.test.sql
git commit -m "feat: add wallet ledger, fn_complete_booking, fn_credit_topup"
```

---

### Task 5: fn_get_booking_service_details

**Files:**
- Create: `supabase/migrations/<ts>_booking_service_details_fn.sql`
- Test: `supabase/tests/database/booking_service_details_fn.test.sql`

**Interfaces:**
- Consumes: `public.bookings`, `public.profiles`, `public.addresses`
- Produces: `public.fn_get_booking_service_details(p_booking_id uuid) returns table(customer_name text, customer_phone text, address_detail text, address_kelurahan text, address_kecamatan text, notes text)`

- [ ] **Step 1: Create the migration file**

Run: `npx supabase migration new booking_service_details_fn`

- [ ] **Step 2: Write the migration**

```sql
create or replace function public.fn_get_booking_service_details(p_booking_id uuid)
returns table (
  customer_name text,
  customer_phone text,
  address_detail text,
  address_kelurahan text,
  address_kecamatan text,
  notes text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_booking public.bookings;
begin
  select * into v_booking from public.bookings where id = p_booking_id;
  if v_booking.id is null or v_booking.barber_id <> auth.uid() then
    raise exception 'not allowed';
  end if;

  return query
  select
    p.full_name,
    case when v_booking.status = 'requested' then null else p.phone end,
    a.detail,
    a.kelurahan,
    a.kecamatan,
    v_booking.notes
  from public.profiles p
  join public.addresses a on a.id = v_booking.address_id
  where p.id = v_booking.customer_id;
end;
$$;

revoke all on function public.fn_get_booking_service_details(uuid) from public;
grant execute on function public.fn_get_booking_service_details(uuid) to authenticated;
```

- [ ] **Step 3: Write the failing pgTAP test**

Create `supabase/tests/database/booking_service_details_fn.test.sql`:

```sql
begin;
select plan(3);

insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('11112222-1111-1111-1111-111111111111', 'cust5@test.dev', '+6281200000001', '{"role":"customer"}'),
  ('22221111-1111-1111-1111-111111111111', 'barb5@test.dev', null, '{"role":"barber"}'),
  ('33334444-1111-1111-1111-111111111111', 'other_barber@test.dev', null, '{"role":"barber"}');

update public.profiles set full_name = 'Budi Santoso' where id = '11112222-1111-1111-1111-111111111111';
update public.barbers set verification_status = 'verified' where id in ('22221111-1111-1111-1111-111111111111', '33334444-1111-1111-1111-111111111111');

insert into public.addresses (id, profile_id, label, provinsi, kota, kecamatan, kelurahan, detail)
values ('44445555-1111-1111-1111-111111111111', '11112222-1111-1111-1111-111111111111', 'Rumah', 'DKI Jakarta', 'Jakarta Selatan', 'Kebayoran Baru', 'Senayan', 'Jl. Test No. 4');

insert into public.services (id, barber_id, catalog_service_id, price_cents, duration_minutes)
select '55556666-1111-1111-1111-111111111111', '22221111-1111-1111-1111-111111111111', id, 5000000, 45
from public.service_catalog limit 1;

insert into public.bookings (id, customer_id, barber_id, service_id, address_id, notes, price_cents, status)
values ('66667777-1111-1111-1111-111111111111', '11112222-1111-1111-1111-111111111111', '22221111-1111-1111-1111-111111111111', '55556666-1111-1111-1111-111111111111', '44445555-1111-1111-1111-111111111111', 'Gerbang hijau', 5000000, 'requested');

set local role authenticated;
set local "request.jwt.claims" to '{"sub":"22221111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select customer_name, customer_phone from public.fn_get_booking_service_details('66667777-1111-1111-1111-111111111111') $$,
  $$ values ('Budi Santoso'::text, null::text) $$,
  'assigned barber sees customer name but masked phone while requested'
);

reset role;
update public.bookings set status = 'accepted' where id = '66667777-1111-1111-1111-111111111111';
set local role authenticated;
set local "request.jwt.claims" to '{"sub":"22221111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select customer_phone from public.fn_get_booking_service_details('66667777-1111-1111-1111-111111111111') $$,
  $$ values ('+6281200000001'::text) $$,
  'phone becomes visible once accepted'
);

reset role;
set local role authenticated;
set local "request.jwt.claims" to '{"sub":"33334444-1111-1111-1111-111111111111","role":"authenticated"}';

select throws_ok(
  $$ select public.fn_get_booking_service_details('66667777-1111-1111-1111-111111111111') $$,
  'not allowed',
  'a different barber cannot read this booking''s customer details'
);

select * from finish();
rollback;
```

- [ ] **Step 4: Run the test, confirm it fails then passes**

Run: `npx supabase db reset && npx supabase test db`
Expected: 3/3 pass.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations supabase/tests/database/booking_service_details_fn.test.sql
git commit -m "feat: add fn_get_booking_service_details for scoped customer visibility"
```

---

### Task 6: wallet-topup-create edge function

**Files:**
- Create: `supabase/functions/wallet-topup-create/extract_qr_details.ts`
- Test: `supabase/functions/wallet-topup-create/extract_qr_details.test.ts`
- Create: `supabase/functions/wallet-topup-create/index.ts`

**Interfaces:**
- Consumes: `public.barbers` (existence check), `public.wallet_transactions` (insert pending row, update with Xendit result) — via `@supabase/supabase-js` service-role client
- Produces: `extractQrDetails(xenditBody: unknown): { qrString: string | null; paymentRequestId: string | null; expiresAt: string | null }`, HTTP endpoint `POST /functions/v1/wallet-topup-create` with body `{ amount_cents: number }`, response `{ transaction_id: string, qr_string: string, expires_at: string | null }`

- [ ] **Step 1: Write the failing test**

Create `supabase/functions/wallet-topup-create/extract_qr_details.test.ts`:

```ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { extractQrDetails } from "./extract_qr_details.ts";

Deno.test("extracts from the actions[]/PRESENT_TO_CUSTOMER shape", () => {
  const body = {
    payment_request_id: "pr-abc123",
    actions: [{ type: "PRESENT_TO_CUSTOMER", descriptor: "QR_STRING", value: "00020101..." }],
    channel_properties: { expires_at: "2026-08-22T10:00:00Z" },
  };
  assertEquals(extractQrDetails(body), {
    qrString: "00020101...",
    paymentRequestId: "pr-abc123",
    expiresAt: "2026-08-22T10:00:00Z",
  });
});

Deno.test("extracts from the paymentMethod.qrCode nested shape", () => {
  const body = {
    id: "pr-xyz789",
    paymentMethod: { qrCode: { qrString: "00020101..." } },
    channelProperties: { expiresAt: "2026-08-22T10:05:00Z" },
  };
  assertEquals(extractQrDetails(body), {
    qrString: "00020101...",
    paymentRequestId: "pr-xyz789",
    expiresAt: "2026-08-22T10:05:00Z",
  });
});

Deno.test("returns nulls when no known shape matches", () => {
  const body = { unexpected: true };
  assertEquals(extractQrDetails(body), { qrString: null, paymentRequestId: null, expiresAt: null });
});
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `deno test supabase/functions/wallet-topup-create/extract_qr_details.test.ts`
Expected: FAIL — `extract_qr_details.ts` doesn't exist yet.

- [ ] **Step 3: Write the implementation**

Create `supabase/functions/wallet-topup-create/extract_qr_details.ts`:

```ts
interface ExtractedQrDetails {
  qrString: string | null;
  paymentRequestId: string | null;
  expiresAt: string | null;
}

// Xendit's own docs disagree with each other on the Payment Requests response
// shape across product generations, so this tries every documented path
// rather than trusting one. See docs/superpowers/specs/2026-08-22-supabase-backend-design.md.
export function extractQrDetails(xenditBody: unknown): ExtractedQrDetails {
  const body = xenditBody as Record<string, unknown>;

  const actions = Array.isArray(body.actions) ? body.actions as Array<Record<string, unknown>> : [];
  const presentAction = actions.find((a) => a.type === "PRESENT_TO_CUSTOMER");
  const paymentMethod = body.paymentMethod as Record<string, unknown> | undefined;
  const qrCode = paymentMethod?.qrCode as Record<string, unknown> | undefined;

  const qrString =
    (presentAction?.value as string | undefined) ??
    (qrCode?.qrString as string | undefined) ??
    (body.qr_string as string | undefined) ??
    null;

  const paymentRequestId =
    (body.id as string | undefined) ??
    (body.payment_request_id as string | undefined) ??
    null;

  const channelPropertiesCamel = body.channelProperties as Record<string, unknown> | undefined;
  const channelPropertiesSnake = body.channel_properties as Record<string, unknown> | undefined;

  const expiresAt =
    (channelPropertiesCamel?.expiresAt as string | undefined) ??
    (channelPropertiesSnake?.expires_at as string | undefined) ??
    null;

  return { qrString, paymentRequestId, expiresAt };
}
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `deno test supabase/functions/wallet-topup-create/extract_qr_details.test.ts`
Expected: 3 passed

- [ ] **Step 5: Write the HTTP handler**

Create `supabase/functions/wallet-topup-create/index.ts`:

```ts
import { createClient } from "npm:@supabase/supabase-js@2";
import { extractQrDetails } from "./extract_qr_details.ts";

const XENDIT_SECRET_KEY = Deno.env.get("XENDIT_SECRET_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

interface TopupRequestBody {
  amount_cents: number;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "method not allowed" }), { status: 405 });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });
  }
  const barberId = userData.user.id;

  let body: TopupRequestBody;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "invalid JSON body" }), { status: 400 });
  }
  if (!Number.isInteger(body.amount_cents) || body.amount_cents <= 0) {
    return new Response(JSON.stringify({ error: "amount_cents must be a positive integer" }), { status: 400 });
  }

  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data: barber, error: barberError } = await adminClient
    .from("barbers")
    .select("id")
    .eq("id", barberId)
    .maybeSingle();
  if (barberError || !barber) {
    return new Response(JSON.stringify({ error: "caller is not a registered barber" }), { status: 403 });
  }

  const { data: tx, error: txError } = await adminClient
    .from("wallet_transactions")
    .insert({ barber_id: barberId, type: "topup", amount_cents: body.amount_cents, status: "pending" })
    .select("id")
    .single();
  if (txError || !tx) {
    return new Response(JSON.stringify({ error: "could not start top-up" }), { status: 500 });
  }

  const xenditResponse = await fetch("https://api.xendit.co/v3/payment_requests", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "api-version": "2024-11-11",
      Authorization: `Basic ${btoa(`${XENDIT_SECRET_KEY}:`)}`,
    },
    body: JSON.stringify({
      amount: body.amount_cents,
      currency: "IDR",
      referenceId: tx.id,
      paymentMethod: {
        type: "QR_CODE",
        reusability: "ONE_TIME_USE",
        qrCode: { channelCode: "QRIS" },
      },
    }),
  });
  const xenditBody = await xenditResponse.json();

  if (!xenditResponse.ok) {
    await adminClient
      .from("wallet_transactions")
      .update({ status: "failed", xendit_raw_response: xenditBody })
      .eq("id", tx.id);
    return new Response(JSON.stringify({ error: "xendit rejected the top-up request" }), { status: 502 });
  }

  const { qrString, paymentRequestId, expiresAt } = extractQrDetails(xenditBody);

  await adminClient
    .from("wallet_transactions")
    .update({
      xendit_payment_request_id: paymentRequestId,
      xendit_qr_string: qrString,
      expires_at: expiresAt,
      xendit_raw_response: xenditBody,
    })
    .eq("id", tx.id);

  if (!qrString || !paymentRequestId) {
    return new Response(JSON.stringify({ error: "top-up created but QR code was not returned, try again" }), { status: 502 });
  }

  return new Response(
    JSON.stringify({ transaction_id: tx.id, qr_string: qrString, expires_at: expiresAt }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});
```

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/wallet-topup-create
git commit -m "feat: add wallet-topup-create edge function"
```

---

### Task 7: xendit-webhook edge function

**Files:**
- Create: `supabase/functions/xendit-webhook/verify_token.ts`
- Test: `supabase/functions/xendit-webhook/verify_token.test.ts`
- Create: `supabase/functions/xendit-webhook/parse_event.ts`
- Test: `supabase/functions/xendit-webhook/parse_event.test.ts`
- Create: `supabase/functions/xendit-webhook/index.ts`
- Modify: `supabase/config.toml`

**Interfaces:**
- Consumes: `public.wallet_transactions`, `public.fn_credit_topup` (RPC) from Task 4
- Produces: `isValidCallbackToken(received: string | null, expected: string): boolean`, `parseTopupEvent(body: unknown): { referenceId: string | null; paymentRequestId: string | null; outcome: 'succeeded' | 'expired' | 'failed' | 'ignored' }`, HTTP endpoint `POST /functions/v1/xendit-webhook`

- [ ] **Step 1: Write the failing test for token verification**

Create `supabase/functions/xendit-webhook/verify_token.test.ts`:

```ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { isValidCallbackToken } from "./verify_token.ts";

Deno.test("accepts a matching token", () => {
  assertEquals(isValidCallbackToken("secret123", "secret123"), true);
});

Deno.test("rejects a non-matching token", () => {
  assertEquals(isValidCallbackToken("wrong", "secret123"), false);
});

Deno.test("rejects a null token", () => {
  assertEquals(isValidCallbackToken(null, "secret123"), false);
});

Deno.test("rejects a token of different length", () => {
  assertEquals(isValidCallbackToken("secret12", "secret123"), false);
});
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `deno test supabase/functions/xendit-webhook/verify_token.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement the token verification**

Create `supabase/functions/xendit-webhook/verify_token.ts`:

```ts
// Constant-time comparison so a timing attack can't be used to guess the
// webhook token byte-by-byte from response latency.
export function isValidCallbackToken(received: string | null, expected: string): boolean {
  if (!received) return false;
  const receivedBytes = new TextEncoder().encode(received);
  const expectedBytes = new TextEncoder().encode(expected);
  if (receivedBytes.length !== expectedBytes.length) return false;

  let diff = 0;
  for (let i = 0; i < receivedBytes.length; i++) {
    diff |= receivedBytes[i] ^ expectedBytes[i];
  }
  return diff === 0;
}
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `deno test supabase/functions/xendit-webhook/verify_token.test.ts`
Expected: 4 passed

- [ ] **Step 5: Write the failing test for event parsing**

Create `supabase/functions/xendit-webhook/parse_event.test.ts`:

```ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { parseTopupEvent } from "./parse_event.ts";

Deno.test("parses a succeeded event, snake_case data shape", () => {
  const body = { event: "payment_request.succeeded", data: { id: "pr-1", reference_id: "tx-1", status: "SUCCEEDED" } };
  assertEquals(parseTopupEvent(body), { referenceId: "tx-1", paymentRequestId: "pr-1", outcome: "succeeded" });
});

Deno.test("parses a succeeded event, camelCase data shape", () => {
  const body = { event: "payment_request.succeeded", data: { id: "pr-2", referenceId: "tx-2", status: "SUCCEEDED" } };
  assertEquals(parseTopupEvent(body), { referenceId: "tx-2", paymentRequestId: "pr-2", outcome: "succeeded" });
});

Deno.test("parses an expired event", () => {
  const body = { event: "payment_request.expired", data: { id: "pr-3", reference_id: "tx-3", status: "EXPIRED" } };
  assertEquals(parseTopupEvent(body), { referenceId: "tx-3", paymentRequestId: "pr-3", outcome: "expired" });
});

Deno.test("ignores an unrecognized event", () => {
  const body = { event: "something.else", data: { id: "pr-4", reference_id: "tx-4", status: "PENDING" } };
  assertEquals(parseTopupEvent(body), { referenceId: "tx-4", paymentRequestId: "pr-4", outcome: "ignored" });
});
```

- [ ] **Step 6: Run the test and confirm it fails**

Run: `deno test supabase/functions/xendit-webhook/parse_event.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 7: Implement event parsing**

Create `supabase/functions/xendit-webhook/parse_event.ts`:

```ts
export type TopupOutcome = "succeeded" | "expired" | "failed" | "ignored";

export interface ParsedTopupEvent {
  referenceId: string | null;
  paymentRequestId: string | null;
  outcome: TopupOutcome;
}

export function parseTopupEvent(body: unknown): ParsedTopupEvent {
  const root = body as Record<string, unknown>;
  const eventName = typeof root.event === "string" ? root.event : "";
  const data = (root.data ?? root) as Record<string, unknown>;

  const referenceId = (data.referenceId as string | undefined) ?? (data.reference_id as string | undefined) ?? null;
  const paymentRequestId = (data.id as string | undefined) ?? (data.payment_request_id as string | undefined) ?? null;
  const status = typeof data.status === "string" ? data.status : "";

  let outcome: TopupOutcome = "ignored";
  if (eventName.includes("succeeded") || status === "SUCCEEDED") outcome = "succeeded";
  else if (eventName.includes("expired") || status === "EXPIRED") outcome = "expired";
  else if (eventName.includes("failed") || status === "FAILED") outcome = "failed";

  return { referenceId, paymentRequestId, outcome };
}
```

- [ ] **Step 8: Run the test and confirm it passes**

Run: `deno test supabase/functions/xendit-webhook/parse_event.test.ts`
Expected: 4 passed

- [ ] **Step 9: Write the HTTP handler**

Create `supabase/functions/xendit-webhook/index.ts`:

```ts
import { createClient } from "npm:@supabase/supabase-js@2";
import { isValidCallbackToken } from "./verify_token.ts";
import { parseTopupEvent } from "./parse_event.ts";

const XENDIT_WEBHOOK_TOKEN = Deno.env.get("XENDIT_WEBHOOK_TOKEN")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }

  const token = req.headers.get("x-callback-token");
  if (!isValidCallbackToken(token, XENDIT_WEBHOOK_TOKEN)) {
    return new Response("invalid token", { status: 401 });
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return new Response("invalid JSON", { status: 400 });
  }

  const event = parseTopupEvent(body);
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  if (!event.referenceId) {
    return new Response(JSON.stringify({ received: true, note: "no reference_id, ignored" }), { status: 200 });
  }

  await adminClient
    .from("wallet_transactions")
    .update({ xendit_raw_response: body })
    .eq("id", event.referenceId);

  if (event.outcome === "succeeded") {
    const { error } = await adminClient.rpc("fn_credit_topup", { p_transaction_id: event.referenceId });
    if (error) {
      console.error("fn_credit_topup failed", error);
      return new Response("internal error", { status: 500 });
    }
  } else if (event.outcome === "expired" || event.outcome === "failed") {
    await adminClient
      .from("wallet_transactions")
      .update({ status: event.outcome })
      .eq("id", event.referenceId)
      .eq("status", "pending");
  }

  return new Response(JSON.stringify({ received: true }), { status: 200 });
});
```

- [ ] **Step 10: Disable JWT verification for this function**

Xendit's webhook calls carry no Supabase JWT — the `x-callback-token` header is the only auth. Edit `supabase/config.toml`, adding this section (near the `[edge_runtime]` block):

```toml
[functions.xendit-webhook]
verify_jwt = false
```

- [ ] **Step 11: Commit**

```bash
git add supabase/functions/xendit-webhook supabase/config.toml
git commit -m "feat: add xendit-webhook edge function"
```

---

### Task 8: End-to-end sandbox smoke test

**Files:** none (verification only — this task exists to catch any Xendit field-name mismatch from Task 6/7's defensive parsing before considering the integration done)

**Interfaces:**
- Consumes: everything from Tasks 1–7, plus the user's real Xendit sandbox keys

- [ ] **Step 1: Start the local stack**

Run: `npx supabase start` (requires Docker running)

- [ ] **Step 2: Set the Xendit secrets**

Run: `npx supabase secrets set XENDIT_SECRET_KEY=<the sandbox secret key> XENDIT_WEBHOOK_TOKEN=<a token you also paste into the Xendit dashboard's Webhook Settings verification token field>`

- [ ] **Step 3: Serve the edge functions locally**

Run: `npx supabase functions serve --env-file supabase/.env.local` (put the two secrets above in that file for local serving; `.env.local` should already be gitignored — confirm with `git check-ignore supabase/.env.local` before proceeding, and if it isn't ignored, add it to `.gitignore` first)

- [ ] **Step 4: Create a test barber user and get a JWT**

Use the local Studio (`http://127.0.0.1:54323`) or the Auth API directly to sign up a user with `{"role": "barber"}` in the metadata, then grab their access token from the sign-in response.

- [ ] **Step 5: Call wallet-topup-create**

Run: `curl -X POST http://127.0.0.1:54321/functions/v1/wallet-topup-create -H "Authorization: Bearer <the barber's JWT>" -H "Content-Type: application/json" -d '{"amount_cents": 25000000}'`
Expected: `200` with a `qr_string` and `transaction_id` in the response. If it 502s with "QR code was not returned", inspect `wallet_transactions.xendit_raw_response` for that row via Studio — this is exactly the case Task 6's defensive parsing was built for; add the actual field path you find to `extractQrDetails` and re-run.

- [ ] **Step 6: Simulate the payment**

Run: `curl -X POST https://api.xendit.co/v3/payment_requests/<payment_request_id from Step 5's DB row>/simulate -H "api-version: 2024-11-11" -H "Authorization: Basic <base64 of your sandbox secret key + colon>" -H "Content-Type: application/json" -d '{"amount": 25000000}'`
Expected: `200` with `{"status": "PENDING"}` — the real result arrives via the webhook next.

- [ ] **Step 7: Confirm the webhook fired and the balance updated**

Check the `wallet-topup-create`/`xendit-webhook` function logs in the `supabase functions serve` terminal for the incoming webhook call, then query `select status, balance_after_cents, xendit_raw_response from wallet_transactions where id = '<transaction_id>'` via Studio's SQL editor.
Expected: `status = 'succeeded'`, `balance_after_cents` reflects the top-up amount. If the webhook never arrives locally, Xendit's dashboard needs a webhook URL it can actually reach (a tunnel like `ngrok` pointed at port 54321) — local-only testing can't receive inbound webhooks without one; note this and fall back to manually invoking `fn_credit_topup` via Studio to at least verify the DB side, flagging the webhook delivery itself as unverified until a tunnel is set up.

- [ ] **Step 8: Record what was actually verified**

No commit for this task (no files changed) — but note in the next status update to the user which of Steps 5–7 actually passed against the real sandbox, and fix `extractQrDetails`/`parseTopupEvent` (with a matching new test case, then re-run Tasks 6/7's `deno test`) for anything that didn't match what Xendit actually returned.

---

## Self-Review Notes

- **Spec coverage:** every table/function/edge-function/RLS rule in the spec has a task (Tasks 1–5 = schema/RLS, 6–7 = Xendit edge functions, 8 = the spec's "Testing" paragraph made concrete).
- **Placeholder scan:** no TBD/TODO; the one open unknown (Xendit's exact response field names) is handled with real defensive code + a real verification task, not a placeholder.
- **Type consistency:** `fn_credit_topup(p_transaction_id uuid)` (Task 4) matches the RPC call `adminClient.rpc("fn_credit_topup", { p_transaction_id: ... })` (Task 7). `fn_get_booking_service_details` return columns (Task 5) match nothing downstream yet (no consumer in this backend-only pass) — correct, since Flutter wiring is out of scope per the spec.
