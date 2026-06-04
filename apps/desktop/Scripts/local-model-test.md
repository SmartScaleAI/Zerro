# Testing models from Xcode (no deploy)

Run a DEBUG build of the app against a **locally served** copy of the
`generate` function, where the model is whatever `supabase/.env.local` says.
Record in the app as normal; the generation runs through Gemini (or any
configured model). Production is untouched; switching models is editing one
line + restarting `serve` — no deploy, no new build.

## How it works

- `ManagedBackend.baseURL` now honors a `ZERRO_FUNCTIONS_BASE_URL` environment
  variable **in DEBUG builds only** (release builds ship pinned to prod).
- `supabase functions serve --env-file supabase/.env.local` runs the edge
  functions locally with your chosen `CHAT_PROVIDER` / `CHAT_MODEL`.
- The local function verifies the same session JWT and talks to the **local**
  database from `supabase start`, so the local DB needs a subscription row
  once (step 2).

## One-time setup

1. `cp supabase/.env.example supabase/.env.local` and fill in:
   - `OPENAI_API_KEY`, `GEMINI_API_KEY`
   - `SESSION_JWT_SECRET` — any value; you'll get a fresh token from the
     LOCAL session endpoint, so it does not need to match prod
   - plus `LEMONSQUEEZY_WEBHOOK_SECRET=localtest` (used only to seed)

2. Start the local stack and seed a subscription:

   ```bash
   supabase start
   supabase functions serve --env-file supabase/.env.local   # leave running
   # in another terminal — seed via the existing webhook test battery:
   export BASE="http://127.0.0.1:54321/functions/v1"
   export WEBHOOK_SECRET="localtest"
   ./supabase/test/run-curl-tests.sh    # creates an active subscription + license key
   ```

   Note the license key the script prints/uses — that's your local login.

3. In Xcode: Product → Scheme → Edit Scheme → Run → Arguments →
   Environment Variables, add:

   | Name | Value |
   |---|---|
   | `ZERRO_FUNCTIONS_BASE_URL` | `http://127.0.0.1:54321/functions/v1` |

## Per-session workflow

```bash
supabase functions serve --env-file supabase/.env.local   # leave running
```

Run the app from Xcode, enter the LOCAL license key in Managed settings
(the debug build's session call goes to the local endpoint), record, generate.
The output came from whatever `CHAT_MODEL` is in `.env.local`.

To compare models: edit `CHAT_MODEL` in `.env.local`, restart `serve`
(Ctrl-C, re-run), generate again with the same kind of recording.

## Gotchas

- The debug build keychain may hold your PROD license/session. If the local
  session call 403s, clear the stored key in the app's Managed settings and
  re-enter the local one.
- `supabase functions serve` serves ALL functions, so `/session`,
  `/entitlement`, `/trial-start` also resolve locally — the whole Managed
  flow stays consistent inside the debug run.
- Remove the scheme env var (or just run a release build) to go back to prod.
- Local generations still spend real OpenAI/Gemini API money (whisper + chat),
  just no Zerro credits drama — the local DB's credits are yours to reset.
