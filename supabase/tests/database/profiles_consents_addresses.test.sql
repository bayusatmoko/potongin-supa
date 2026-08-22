begin;
select plan(7);

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

select throws_ok(
  $$ update public.profiles set role = 'barber' where id = '11111111-1111-1111-1111-111111111111' $$,
  'permission denied for table profiles',
  'authenticated user cannot update role column (prevents self-escalation)'
);

select * from finish();
rollback;
