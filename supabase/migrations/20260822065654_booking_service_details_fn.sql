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
