begin;
select plan(5);

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

reset role;
update public.bookings set status = 'declined' where id = '66667777-1111-1111-1111-111111111111';
set local role authenticated;
set local "request.jwt.claims" to '{"sub":"22221111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select customer_phone from public.fn_get_booking_service_details('66667777-1111-1111-1111-111111111111') $$,
  $$ values (null::text) $$,
  'phone remains masked when booking is declined'
);

reset role;
update public.bookings set status = 'cancelled' where id = '66667777-1111-1111-1111-111111111111';
set local role authenticated;
set local "request.jwt.claims" to '{"sub":"22221111-1111-1111-1111-111111111111","role":"authenticated"}';

select results_eq(
  $$ select customer_phone from public.fn_get_booking_service_details('66667777-1111-1111-1111-111111111111') $$,
  $$ values (null::text) $$,
  'phone remains masked when booking is cancelled'
);

select * from finish();
rollback;
