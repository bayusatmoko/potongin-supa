# Cukur — Supabase Backend Design (MVP schema + Xendit wallet top-up)

Status: approved by user, pending implementation plan
Date: 2026-08-22
Scope: full MVP Postgres schema, RLS, and the barber wallet top-up integration with Xendit. Flutter app wiring is a later phase.

## Context

`supabase/` is freshly scaffolded (`supabase init` only, no migrations). The product is Cukur, a home-barber booking app for Indonesia — see root `CLAUDE.md` for product context. The UI is designed in a Claude Design canvas (project `67b1f608-5cb0-4e86-a990-f2f56ea4448a`, file `Home Barber App.dc.html`, turns `2a`–`2h`). This spec is grounded directly in that canvas, not guessed from the product description alone.

The user decided to use **Xendit** as the payment gateway (see memory `cukur_payment_provider`). Reading the actual screens surfaced an important scope reduction: **customer → barber payment is not an in-app gateway flow.** The "Bayar" screen just shows a total and a "BAYAR" button captioned "DIMAS KONFIRMASI SETELAH DITERIMA" (barber confirms once received) — money changes hands outside the app (cash / personal QRIS), and the app only records a manual confirmation step. The 5% app fee is a pure internal ledger deduction from the barber's credit balance on booking completion. The **only** real Xendit integration point is the barber's wallet top-up flow (turn `2e`): pick a nominal amount → confirm (Rp 0 admin fee shown) → "Menunggu pembayaran" QR screen → balance auto-credited within ~1 minute of payment → receipt showing `METODE: QRIS · GoPay`, `WAKTU`, `NOMINAL`.

## Goals

- Full Postgres schema (migrations) covering: profiles, addresses, barbers, service catalog + barber pricing, bookings, ratings, wallet ledger, consent records.
- RLS policies enforcing the asymmetric visibility the product needs (see below).
- Xendit-backed QRIS top-up for barber wallets: create → pay → webhook-confirmed credit, using Xendit's Payment Requests API against test-mode keys.
- Internal fee-deduction ledger entry on booking completion (no gateway involved).

## Non-goals (this pass)

- No in-app customer→barber payment gateway flow (confirmed out of scope by the design itself).
- No automated KTP/Mode Muslimah verification workflow — `verification_status` / `mode_muslimah_status` are flipped manually/offline (e.g. via Supabase Studio); no review-queue tables or admin tooling.
- No admin app/dashboard.
- No Flutter/client wiring — schema, RLS, and edge functions only.
- No `service_catalog` write path from the client — seeded via migration/seed data only.

## Data model

```
profiles
  - id (=auth.users.id), phone, full_name, avatar_url, gender, role ('customer'|'barber'), created_at

user_consents                       -- audit trail, UU PDP 27/2022 compliance
  - id, profile_id, consent_type ('data_processing'|'ktp_verification'),
    terms_version, granted_at

addresses
  - id, profile_id, label, provinsi, kota, kecamatan, kelurahan,
    detail, lat, lng, is_default

barbers                             -- 1:1 extension of a 'barber' profile
  - id (=profiles.id), nik, ktp_photo_url, selfie_photo_url,
    verification_status ('pending'|'verified'|'rejected'),
    mode_muslimah_status ('none'|'verified'),
    rating_avg, rating_count, vehicle_desc, credit_balance_cents, created_at

barber_service_areas                -- many-to-many: barber <-> kelurahan served
  - barber_id, kelurahan

service_catalog                     -- predefined/admin-maintained service list
  - id, name, description, icon, category, is_active

services                            -- barber's own price for a catalog item
  - id, barber_id, catalog_service_id, price_cents, duration_minutes, is_active

bookings
  - id, customer_id, barber_id, service_id, address_id, notes,
    status, price_cents, app_fee_cents,
    scheduled_at, accepted_at, en_route_at, arrived_at, started_at,
    completed_at, paid_confirmed_at, created_at

booking_ratings
  - booking_id, customer_id, barber_id, stars, comment, created_at

wallet_transactions                 -- append-only ledger
  - id, barber_id, type ('topup'|'fee'), amount_cents, balance_after_cents,
    booking_id (nullable, set for 'fee' rows),
    xendit_payment_request_id (nullable, set for 'topup' rows),
    status ('pending'|'succeeded'|'expired'|'failed'),
    created_at, settled_at
```

`barbers.credit_balance_cents` is a denormalized cache of `SUM(wallet_transactions.amount_cents)` for that barber, kept in sync by only ever writing both inside one atomic DB function — never via direct client UPDATE. This trades a small amount of write-path complexity (two functions, see below) for O(1) balance reads on screens that show it constantly (home, wallet).

## Booking status machine

```
requested → accepted → en_route → arrived → in_progress → completed → paid_confirmed → rated
                ↘ declined                ↘ cancelled (before in_progress)
```

Grounded in the tracking screen's stepper (`DITERIMA → DI JALAN → SAMPAI → MULAI`) plus the surrounding flow. Status transitions are not raw client UPDATEs — `fn_complete_booking(booking_id)` is the only path from `in_progress`/`arrived` to `completed`, and it atomically: updates the booking row, inserts a `wallet_transactions` `type='fee'` row (flat 5% of `price_cents`), and decrements `barbers.credit_balance_cents`. `paid_confirmed` is a plain status update triggered by the barber tapping confirm — no gateway involved.

## Row-Level Security

- **`profiles`, `addresses`, `user_consents`**: owner-only (`auth.uid() = id` / `profile_id`). No general "other party" read policy.
- **`barbers`, `services`, `service_catalog`, `barber_service_areas`**: public read (customers browse without a booking); write restricted to the owning barber (`service_catalog` has no client write path at all). NIK/KTP/selfie/verification columns on `barbers` are only readable by the owning barber — enforced via a restricted view or column-level policy, not the public-read table policy.
- **Barber's view of a customer is intentionally narrow**: no RLS grant on `profiles`/`addresses` for barbers. Instead, `fn_get_booking_service_details(booking_id)` — security-definer, callable only by that booking's assigned barber — returns just customer name, phone (masked until `accepted`, full after, for coordination), the one address tied to that booking, and `notes`. This is the only door a barber has into customer data, scoped to one active booking at a time.
- **`bookings`, `booking_ratings`**: readable/writable only by the two parties (`customer_id`/`barber_id` = `auth.uid()`); status transitions go through functions (`fn_accept_booking`, `fn_complete_booking`, etc.), not raw UPDATE, so a customer can't jump straight to `paid_confirmed`.
- **`wallet_transactions`**: owning barber, read-only from the client — all writes happen through `fn_credit_topup` / `fn_complete_booking` or the webhook handler, never a direct client insert.

## Xendit wallet top-up integration

Two edge functions:

**1. `wallet-topup-create`** (called by the barber from the app)
- Input: `amount_cents`
- Inserts a `wallet_transactions` row (`type='topup'`, `status='pending'`, `amount_cents`) — balance not yet touched
- Calls Xendit's **Payment Requests API**: `POST /v3/payment_requests` with `payment_method: { type: "QR_CODE", qr_code: { channel_code: "QRIS" } }`, `amount`
- Stores the returned `payment_request_id` as `xendit_payment_request_id` and the `qr_string` on the transaction row; returns the QR string + expiry to the app

**2. `xendit-webhook`** (public, called by Xendit)
- Verifies the `x-callback-token` header against the `XENDIT_WEBHOOK_TOKEN` Supabase secret — the only auth on this endpoint, reject on mismatch
- On a succeeded-payment event: looks up the `wallet_transactions` row by `xendit_payment_request_id`; if still `status='pending'` (webhooks can retry — this check makes the handler idempotent), calls `fn_credit_topup(transaction_id)`, which atomically sets `status='succeeded'`, `settled_at=now()`, and increments `barbers.credit_balance_cents`
- On expired/failed events: marks the row accordingly, no balance change

**Secrets** (`supabase secrets set`, sandbox first since the user has test keys): `XENDIT_SECRET_KEY`, `XENDIT_WEBHOOK_TOKEN`.

**Testing**: Xendit test mode requires no merchant/QRIS onboarding — it works immediately after account signup. A payment is simulated via `POST /v3/payment_requests/{payment_request_id}/simulate` (`{"amount": ...}`, header `api-version: 2024-11-11`), which returns `status: "PENDING"` immediately and delivers the real result asynchronously via the webhook — so the full webhook path is exercised in testing, not mocked. Live mode has a separate QRIS merchant-activation requirement, out of scope for this pass.

## Migration plan

Numbered migrations in `supabase/migrations/`, RLS policies co-located with the table that owns them (per existing `supabase/CLAUDE.md` convention):

1. `profiles`, `user_consents`, `addresses` + RLS
2. `barbers`, `barber_service_areas`, `service_catalog` (+ seed data), `services` + RLS
3. `bookings`, `booking_ratings` + status-transition functions + RLS
4. `wallet_transactions` + `fn_credit_topup`, `fn_complete_booking` + RLS
5. `fn_get_booking_service_details` (security-definer function)
6. Edge functions: `wallet-topup-create`, `xendit-webhook`

## Open items / assumptions carried into implementation

- Supabase phone-OTP auth requires an SMS provider (e.g. Twilio) configured in Auth settings — that account/credential setup is outside what can be done from this session; implementation will wire the schema/RLS to work with phone auth but the actual provider configuration is a manual step for the user.
- Xendit sandbox API keys: user has them; will be set as Supabase secrets during implementation.
- Xendit QRIS live-mode merchant activation is a separate, manual Xendit dashboard step not covered here.
