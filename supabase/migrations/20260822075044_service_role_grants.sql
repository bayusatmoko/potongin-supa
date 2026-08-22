-- service_role bypasses RLS but still needs base-table GRANTs to touch a
-- table at all. Tasks 1-5 only granted anon/authenticated; the edge functions
-- (wallet-topup-create, xendit-webhook) use a service-role client to read
-- `barbers` and read/write `wallet_transactions` directly, which was
-- unusable until now (found via Task 8's live sandbox smoke test).
grant select on public.barbers to service_role;
grant select, insert, update on public.wallet_transactions to service_role;
