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
