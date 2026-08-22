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

grant select, insert on public.bookings to authenticated;

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
       or v_booking.status not in ('requested','accepted','en_route','arrived') then
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

grant select on public.booking_ratings to authenticated;

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
