# Cukur Backend API Documentation

Live project: `https://qjvcjzudjqnpqpibhhhz.supabase.co` (ref `qjvcjzudjqnpqpibhhhz`)
Local dev (ports remapped off Windows' excluded range — see `supabase/config.toml`): API `http://127.0.0.1:55321`, Studio `http://127.0.0.1:55323`, DB `http://127.0.0.1:55322`

Every request needs the `apikey` header set to the project's anon/publishable key (client-safe, safe to embed in the Flutter app). Authenticated requests additionally need `Authorization: Bearer <access_token>` from a signed-in session.

Spec: `docs/superpowers/specs/2026-08-22-supabase-backend-design.md`
Plan: `docs/superpowers/plans/2026-08-22-supabase-backend.md`

---

## 1. Auth

Standard Supabase Auth (GoTrue) REST API, mounted at `/auth/v1`. `role` is passed via `data`/`user_metadata` at signup time — the `handle_new_user()` trigger reads it to create the matching `profiles` row (and a stub `barbers` row if `role: "barber"`).

### Sign up — email/password
```
POST /auth/v1/signup
Headers: apikey: <anon key>
Body: { "email": "...", "password": "...", "data": { "role": "customer" | "barber" } }
```
Returns `{ access_token, refresh_token, user, ... }` if email confirmation is off, or a user with `confirmed_at: null` if confirmation is required (hosted project's Auth settings — check Dashboard → Authentication → Sign In / Email — this was never touched by this backend's migrations, only the schema/functions were deployed).

### Sign up / sign in — phone or WhatsApp OTP
Requires a real SMS provider (e.g. Twilio) configured in Dashboard → Authentication → Sign In / Phone. Not configured on the live project as of this writing.

Step 1 — request the code:
```
POST /auth/v1/otp
Headers: apikey: <anon key>
Body: { "phone": "62812xxxxxxxx", "channel": "sms" | "whatsapp", "data": { "role": "customer" }, "create_user": true }
```

Step 2 — verify and complete signup/login:
```
POST /auth/v1/verify
Headers: apikey: <anon key>
Body: { "type": "sms", "phone": "62812xxxxxxxx", "token": "<6-digit code>" }
```
Returns `{ access_token, refresh_token, user, ... }`. `"type": "sms"` is correct even when the code was delivered via WhatsApp.

### Log in — email/password
```
POST /auth/v1/token?grant_type=password
Headers: apikey: <anon key>
Body: { "email": "...", "password": "..." }
```

### Refresh a session
```
POST /auth/v1/token?grant_type=refresh_token
Headers: apikey: <anon key>
Body: { "refresh_token": "<refresh_token>" }
```

### Admin: create a pre-confirmed user (testing/seeding only — never call from the app)
```
POST /auth/v1/admin/users
Headers: apikey: <service_role key>, Authorization: Bearer <service_role key>
Body: { "email": "...", "password": "...", "email_confirm": true, "user_metadata": { "role": "barber" } }
```

---

## 2. Data API (PostgREST, `/rest/v1/<table>`)

All tables are exposed via Supabase's auto-generated REST API. Every request needs `apikey: <anon key>` and, for anything requiring `authenticated`, `Authorization: Bearer <access_token>`. RLS enforces the access rules below — the client never needs to filter by user id manually, but understanding these rules matters for what a UI can and can't fetch.

| Table | Read | Write |
|---|---|---|
| `profiles` | owner only | owner can update `full_name`, `avatar_url`, `gender` only (not `role`, not `phone`) — no client insert (created by trigger on signup) |
| `user_consents` | owner only | owner can insert only (append-only, no update/delete) |
| `addresses` | owner only | owner: full insert/update/delete |
| `barbers` | owner only (full row, incl. NIK/KTP) | owner can update `nik`, `ktp_photo_url`, `selfie_photo_url`, `vehicle_desc` only — `verification_status`, `mode_muslimah_status`, `credit_balance_cents` are server-only |
| `barbers_public` (view) | public (`anon` + `authenticated`) | read-only. Columns: `id, rating_avg, rating_count, vehicle_desc, mode_muslimah_status`. Only verified barbers appear. Use this for browsing, never the base `barbers` table. |
| `service_catalog` | public | none (seeded via migration only) |
| `services` | public | owning barber: full insert/update/delete |
| `barber_service_areas` | public | owning barber: full insert/update/delete |
| `bookings` | either party (`customer_id` or `barber_id` = caller) | customer can `insert` (creates with `status: 'requested'`); **no client update at all** — every status change goes through `fn_transition_booking` / `fn_complete_booking` (§3) |
| `booking_ratings` | either party | **no client insert** — only via `fn_submit_rating` (§3) |
| `wallet_transactions` | owning barber only | **no client write at all** — only via `fn_complete_booking` / `fn_credit_topup` (§3) or the edge functions (service_role) |

Example — fetch a barber's own bookings:
```
GET /rest/v1/bookings?barber_id=eq.<auth.uid()>&select=*
Headers: apikey, Authorization: Bearer <token>
```
(RLS makes the `barber_id=eq...` filter redundant for security, but PostgREST still needs an explicit filter or `select=*` to know what to return — RLS narrows the result set regardless of what's requested.)

A barber never gets general read access to a customer's `profiles`/`addresses` row — see `fn_get_booking_service_details` in §3 for the one sanctioned, booking-scoped exception.

---

## 3. RPC functions (`POST /rest/v1/rpc/<function_name>`)

All calls need `apikey` + `Authorization: Bearer <access_token>` unless noted. Body is a JSON object of the function's named parameters.

### `fn_transition_booking`
Drives every booking status change except `completed` (see `fn_complete_booking`) and `rated` (see `fn_submit_rating`).
```
POST /rest/v1/rpc/fn_transition_booking
Body: { "p_booking_id": "<uuid>", "p_new_status": "accepted" | "declined" | "en_route" | "arrived" | "in_progress" | "cancelled" | "paid_confirmed" }
```
Valid transitions (caller must be the correct party or the call raises `not allowed`):
```
requested --(barber)--> accepted --(barber)--> en_route --(barber)--> arrived --(barber)--> in_progress
requested --(barber)--> declined
{requested,accepted,en_route,arrived} --(either party)--> cancelled
completed --(barber)--> paid_confirmed
```
Returns the updated `bookings` row.

### `fn_complete_booking`
Barber marks an `in_progress` job done. Computes the flat 5% app fee server-side, deducts it from `barbers.credit_balance_cents` (raises `insufficient credit balance for the app fee` if the balance can't cover it — the client should catch this and prompt a top-up), and writes a `wallet_transactions` `'fee'` ledger row.
```
POST /rest/v1/rpc/fn_complete_booking
Body: { "p_booking_id": "<uuid>" }
```
Returns the updated `bookings` row (`status: 'completed'`, `app_fee_cents` populated).

### `fn_submit_rating`
Customer rates a `paid_confirmed` booking. Sets the booking to `rated` and recomputes the barber's `rating_avg`/`rating_count`.
```
POST /rest/v1/rpc/fn_submit_rating
Body: { "p_booking_id": "<uuid>", "p_stars": 1-5, "p_comment": "<text or null>" }
```
Returns the new `booking_ratings` row.

### `fn_get_booking_service_details`
The barber's only window into a customer's contact info — scoped to one booking they're assigned to.
```
POST /rest/v1/rpc/fn_get_booking_service_details
Body: { "p_booking_id": "<uuid>" }
```
Returns a single row: `customer_name, customer_phone, address_detail, address_kelurahan, address_kecamatan, notes`. `customer_phone` is `null` while the booking is `requested`, `declined`, or `cancelled` — only visible once actually `accepted` or beyond.

### `fn_credit_topup` — **service_role only, never call from the app**
Credits a barber's wallet from a `pending` top-up transaction. Idempotent (a second call on an already-`succeeded` transaction is a no-op). Called internally by the `xendit-webhook` edge function.
```
POST /rest/v1/rpc/fn_credit_topup
Headers: apikey/Authorization: service_role key
Body: { "p_transaction_id": "<uuid>" }
```

---

## 4. Edge Functions (`/functions/v1/<name>`)

### `POST /functions/v1/wallet-topup-create`
Barber-initiated. Creates a `wallet_transactions` `'topup'` row and a Xendit QRIS payment request.
```
Headers: apikey: <anon key>, Authorization: Bearer <barber's access_token>
Body: { "amount_cents": <positive integer> }
```
Success `200`: `{ "transaction_id": "<uuid>", "qr_string": "<QRIS payload to render as a QR code>", "expires_at": "<ISO timestamp or null>" }`
Errors: `401` unauthorized, `403` caller isn't a registered barber, `400` bad `amount_cents`, `502` Xendit call failed / rejected / didn't return a QR code (retry-safe — the underlying `wallet_transactions` row is marked `failed`).

Note from the live sandbox smoke test: Xendit's real Payment Requests API (api-version `2024-11-11`) uses a **flat** request body (`type: "PAY"`, `channel_code: "QRIS"` as top-level fields — see `supabase/functions/wallet-topup-create/build_payment_request.ts`), not the nested `payment_method.qr_code.channel_code` shape some Xendit docs/SDKs show.

### `POST /functions/v1/xendit-webhook`
Xendit-initiated (public — no Supabase JWT, `verify_jwt: false`). The **only** auth is the `x-callback-token` header, checked via constant-time comparison against the `XENDIT_WEBHOOK_TOKEN` secret. This token must also be set in the Xendit Dashboard's Webhook Settings verification-token field so both sides match.
```
Headers: x-callback-token: <XENDIT_WEBHOOK_TOKEN>
Body: Xendit's payment_request event payload
```
On a succeeded event: calls `fn_credit_topup` (idempotent, safe on webhook retries). On expired/failed: marks the transaction accordingly. Always persists the raw payload to `wallet_transactions.xendit_raw_response` for debugging, regardless of outcome.

**Required secrets** (Dashboard → Project Settings → Edge Functions → Secrets, or `supabase secrets set`): `XENDIT_SECRET_KEY` (server-side Xendit API calls), `XENDIT_WEBHOOK_TOKEN` (webhook auth). Both are currently only in the local `supabase/.env.local` (gitignored) — need to be set on the live project separately.

---

## 5. Data model reference

```
profiles(id, phone, full_name, avatar_url, gender, role, created_at)
user_consents(id, profile_id, consent_type, terms_version, granted_at)
addresses(id, profile_id, label, provinsi, kota, kecamatan, kelurahan, detail, lat, lng, is_default, created_at)
barbers(id, nik, ktp_photo_url, selfie_photo_url, verification_status, mode_muslimah_status, rating_avg, rating_count, vehicle_desc, credit_balance_cents, created_at)
barbers_public(id, rating_avg, rating_count, vehicle_desc, mode_muslimah_status)  -- view, verified barbers only
service_catalog(id, name, description, icon, category, is_active)
services(id, barber_id, catalog_service_id, price_cents, duration_minutes, is_active, created_at)
barber_service_areas(barber_id, kelurahan)
bookings(id, customer_id, barber_id, service_id, address_id, notes, status, price_cents, app_fee_cents,
         scheduled_at, accepted_at, en_route_at, arrived_at, started_at, completed_at, paid_confirmed_at,
         cancelled_at, created_at)
booking_ratings(booking_id, customer_id, barber_id, stars, comment, created_at)
wallet_transactions(id, barber_id, type, amount_cents, balance_after_cents, booking_id,
                     xendit_payment_request_id, xendit_qr_string, xendit_raw_response, expires_at,
                     status, created_at, settled_at)
```

- Money is always integer cents (`price_cents`, `amount_cents`, etc.) — `Rp X` displayed to users is `X * 100`.
- `bookings.status`: `requested → accepted → en_route → arrived → in_progress → completed → paid_confirmed → rated`, with `declined` (from `requested` only) and `cancelled` (from `requested`/`accepted`/`en_route`/`arrived` only) as side branches.
- `wallet_transactions.type`: `'topup'` (positive `amount_cents`) or `'fee'` (negative `amount_cents`, tied to a `booking_id`).
- `wallet_transactions.status`: `pending → succeeded | expired | failed`.

## 6. Known gaps / follow-ups (not yet done)

- Hosted project's Auth settings (email confirmation on/off, phone/SMS provider) were never configured by this backend build — only schema and edge functions were deployed. Needs a deliberate decision + Dashboard configuration.
- `XENDIT_SECRET_KEY` / `XENDIT_WEBHOOK_TOKEN` secrets not yet set on the live project.
- No app-level maximum on `amount_cents` for top-ups (Xendit's real QRIS limit is below the 25,000,000 test value used during development).
- `fn_credit_topup` is intentionally not `SECURITY DEFINER` (service_role-only caller bypasses RLS anyway) — flagged in review as a minor inconsistency with its sibling `fn_complete_booking`, not fixed.
