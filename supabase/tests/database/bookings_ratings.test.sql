begin;
select plan(8);

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

select lives_ok(
  $$ select public.fn_transition_booking('99999999-9999-9999-9999-999999999999', 'cancelled') $$,
  'barber can cancel an accepted booking'
);

reset role;
set local role authenticated;
set local "request.jwt.claims" to '{"sub":"55555555-5555-5555-5555-555555555555","role":"authenticated"}';

insert into public.bookings (id, customer_id, barber_id, service_id, address_id, price_cents, status)
values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '55555555-5555-5555-5555-555555555555', '66666666-6666-6666-6666-666666666666', '88888888-8888-8888-8888-888888888888', '77777777-7777-7777-7777-777777777777', 5000000, 'requested');

reset role;
set local role authenticated;
set local "request.jwt.claims" to '{"sub":"66666666-6666-6666-6666-666666666666","role":"authenticated"}';

select lives_ok(
  $$ select public.fn_transition_booking('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'declined') $$,
  'barber can decline a requested booking'
);

select throws_ok(
  $$ select public.fn_transition_booking('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cancelled') $$,
  'not allowed',
  'cannot cancel a declined booking'
);

select * from finish();
rollback;
