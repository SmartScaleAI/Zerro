# Resetting Zerro to a first-time user

These commands reset one verified email and this Mac in one Zerro environment.
Every destructive run first previews the matching database rows, requires
confirmation, and then removes both the scoped Supabase state and local macOS
state.

## One-time remote setup

Local uses the running Supabase CLI stack. Staging and production read encoded
Postgres connection strings from the existing ignored `supabase/.env.local`
file. Get each value from the matching Supabase dashboard's **Connect** dialog.

```bash
ZERRO_STAGING_DB_URL=postgresql://postgres.waripvlpcpwdmacpjiqc:ENCODED_PASSWORD@HOST:5432/postgres
ZERRO_PRODUCTION_DB_URL=postgresql://postgres.wjxqmurgwyxwkezncxke:ENCODED_PASSWORD@HOST:5432/postgres
```

Shell environment variables with the same names can still override the file.
Each remote script verifies the URL's hard-coded project ref, so a staging
command cannot accidentally target production. The scripts never use whichever
project happens to be linked in `supabase/.temp/project-ref`.

## Commands

```bash
# Local Supabase + local Debug app state
apps/desktop/Scripts/reset-local.sh --email you@example.com

# Staging Supabase + Zerro Staging app state
apps/desktop/Scripts/reset-staging.sh --email you@example.com

# Production Supabase + production Zerro app state
apps/desktop/Scripts/reset-production.sh --email you@example.com
```

Add `--client-ip 203.0.113.10` when repeated tests may have consumed the
per-IP onboarding rate limit. Add `--delete-app` to remove the selected app from
`/Applications` too. Local and staging can use `--yes` in automation;
production always requires the typed confirmation.

Use `--preview-only` to inspect exactly what would match without reaching a
confirmation prompt or deleting anything.

By default, the database reset removes:

- the email verification code, verified onboarding contact, managed trial,
  current-Mac trial claim, BYOK trial, BYOK usage events, and generation slots;
- matching generation/convert idempotency and identity/email/device rate-limit
  rows (plus IP rows when `--client-ip` is supplied);
- local preferences, onboarding flags, TCC permissions, caches, logs, recent
  artifacts, provider keys, license/trial tokens, and the local Whisper model.

The Whisper model lives in the hard-coded shared
`~/Library/Application Support/Zerro/models` directory, so resetting any build
channel removes the model used by all three channels.

Local Debug and Production also currently share the
`com.cbreeding.Zerro` bundle identifier. Their Supabase rows are reset
independently, but their on-Mac preferences, permissions, Keychain items, and
caches cannot be isolated: running either reset clears the shared local state.
Staging has its own bundle identifier, although it still shares the hard-coded
Application Support directory above.

## Paid test accounts

If this email also has a paid subscription mirror in Supabase, the preview
reports it but leaves it intact by default. To delete that mirror and its usage
periods, top-ups, holds, generation logs, and caches, add:

```bash
--include-billing
```

This does **not** cancel or delete the LemonSqueezy customer/subscription. A
later LemonSqueezy webhook can recreate the Supabase mirror. Use this option
only with a test-mode billing identity whose external state you understand.

Zerro does not create Supabase Auth users, so there is no Auth user to delete.
The reset also intentionally leaves global/unscoped records such as webhook
idempotency events, IP attribution rows, and managed-trial generation log rows
whose schema has no trial-grant identifier.
