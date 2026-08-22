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

grant select on public.wallet_transactions to authenticated;

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
