# Cukur — Supabase Backend

Postgres schema, migrations, edge functions, and auth config for Cukur. See the parent `../CLAUDE.md` for product context. `project_id` in `config.toml` is `cukur`.

The Supabase CLI is not installed globally on this machine — invoke it via `npx supabase@latest <command>` (or install it locally with `npm install --save-dev supabase` / via `scoop` if it'll be used often; the CLI explicitly refuses a global `npm install -g`).

## Status

Freshly scaffolded via `supabase init` — `config.toml` only. No migrations, no linked remote project, local stack never started. Nothing to connect the Flutter app to yet.

## Commands

```
npx supabase start          # boot local stack (Postgres, Auth, Storage, Studio) — needs Docker running
npx supabase stop
npx supabase db diff -f <name>   # generate a migration from local schema changes
npx supabase migration new <name>
npx supabase db reset        # rebuild local DB from migrations + seed.sql
npx supabase link --project-ref <ref>   # link to a hosted project before pushing
npx supabase db push
```

## Schema notes (not yet implemented)

Based on the design canvas flows (`2a`–`2h` in the parent's design source), the core entities will be roughly: `profiles` (role: customer/barber, gender, verified flag for Mode Muslimah eligibility), `barbers` (KTP/NIK verification status, services & self-set pricing, credit balance), `services`, `bookings` (status machine: requested → accepted → en route → in progress → completed → paid/rated), `addresses` (down to *kelurahan*), and a `wallet_transactions` table for the barber's top-up/fee-deduction balance. Treat this as a starting hypothesis, not a spec — confirm against the actual screens before writing migrations.

Put every schema change in `migrations/` as a numbered SQL migration (never hand-edit the local DB and forget to capture it); keep RLS policies alongside the table that owns them in the same migration.
