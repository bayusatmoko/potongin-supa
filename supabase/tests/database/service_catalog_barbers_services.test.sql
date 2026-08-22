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
  'permission denied for table barbers',
  'a barber cannot self-write verification_status'
);

select * from finish();
rollback;
