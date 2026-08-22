# Cukur — Home Barber Booking App

Monorepo root. Two independent projects live side by side here:

- **`app/`** — Flutter client (customer + barber/*penata*-facing mobile app). See `app/CLAUDE.md`.
- **`supabase/`** — Supabase backend: Postgres schema, migrations, edge functions, auth config. See `supabase/CLAUDE.md`.

Read the subproject's `CLAUDE.md` before working inside it — this file only covers things that span both.

## Product

Cukur is a home-barber service app for Indonesia (localized: Rupiah, Jakarta down to *kelurahan* level, Bahasa Indonesia UI, motorbike-based logistics, QRIS top-up). Two user roles:

- **Pelanggan** (customer) — books a home haircut, tracks the barber en route, pays, rates.
- **Penata** (barber/stylist) — onboards with KTP/NIK verification, sets own services & pricing, receives orders, tops up a credit balance the 5% app fee is drawn from (customer payment goes 100% to the barber).

A distinguishing feature: **Mode Muslimah** — an opt-in, verified female-only stylist mode with private sessions and no client photos taken.

## Design source

The UI is designed in a Claude Design canvas project (id `67b1f608-5cb0-4e86-a990-f2f56ea4448a`, file `Home Barber App.dc.html`), imported via the `claude_design` MCP (`DesignSync` tool). It contains two turns:

- Turn 1 (`1a`) — earlier Lagos/Nigeria version, kept for reference only.
- Turn 2 (`2a`–`2h`) — current Indonesia/Cukur version: customer flow, two home-screen alternatives (map-first vs. typographic list), one-screen rebook, the barber-side app, Mode Muslimah, and both onboarding flows.

The design system is called **Modernist** — brutalist/editorial: off-white background (`#f3f2f2`), near-black text (`#201e1d`), red-orange accent (`#ec3013`), Archivo typeface at weight 800 for headings, zero border-radius, heavy 2px borders. Its token/component CSS lives in the design project at `_ds/modernist-c12330b7-a428-49f0-aaf8-f47be901cd62/styles.css` — treat it as the source of truth for colors/spacing/type when building Flutter theming, not the ad-hoc inline styles used in the canvas mockup itself.

To re-read the canvas or pull specific screens, use the `DesignSync` MCP tool (`get_project` / `list_files` / `get_file`) against that project id — don't guess at screen content from memory.

## Status

Both `app/` and `supabase/` are freshly scaffolded (`flutter create`, `supabase init`) — no schema, no screens, no wiring between them yet. Next steps: design the Postgres schema (users, barbers, bookings, services, payments/wallet) in `supabase/migrations`, then build the Flutter screens against it, starting from the customer spine (`2a`/`2g`).
