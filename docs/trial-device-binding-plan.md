# Trial abuse hardening — device binding

Status: **Plan / pre-implementation**
Author: drafted with Claude, 2026-06-18
Scope: close the "different emails, same computer" trial-farming hole before launch.

---

## 1. The problem

Today a trial is **a pool of 40 server-funded credits keyed to one verified email**
(`trial_grants.email_normalized UNIQUE`). The anti-abuse controls are all
email- or velocity-based:

- Gmail dot/`+tag` collapse + non-Gmail `+tag` strip (`normalizeEmail`)
- disposable-domain blocklist (`DISPOSABLE_DOMAINS`)
- per-email + per-IP fixed-window rate limits (`check_rate_limit`)
- one grant per normalized email, never reset (`verify_trial_grant`)

**None of these stop the actual attack.** A real person on one Mac can create a
genuinely different real address (a fresh Gmail, an Outlook/iCloud/work email),
verify it, and collect another 40 credits — indefinitely. Normalization and the
disposable list don't catch distinct, legitimate addresses. There is **no
device-level binding anywhere** on the trial grant.

The cost is direct: every farmed grant is server-funded OpenAI spend we pay for
with no path to conversion.

## 2. The fix (decided)

Bind each trial grant to **one physical Mac**, identified by a hashed hardware
identifier, and **hard-block** a second grant from a device that already used
its trial — regardless of which email is presented.

Decisions locked for this plan:

- **Primary mechanism:** device binding (hashed hardware ID). No card required.
- **Strictness:** hard block. One trial per machine, period.
- **Email cap, disposable block, and rate limits stay** as a second layer
  (defense in depth). A new grant now requires *both* a new email *and* a new
  physical machine.

### Why this works here when it wouldn't for a web app

Zerro is a **notarized, non-sandboxed macOS app** (entitlements carry no
`com.apple.security.app-sandbox`; distribution is DMG + Sparkle, not the Mac App
Store). That means the app can read a **stable per-machine hardware UUID** with
no special entitlement and no TCC permission prompt — something a browser can
never do reliably. We get a hard, near-unforgeable device key instead of fuzzy
browser fingerprinting.

### Threat model — what this stops vs. what it doesn't

**Stops (the real-world attack):** casual email cycling on one machine. Making a
new email is trivial; this makes it worthless because the device is already
burned.

**Accepted residual risks (document, don't over-engineer):**

- A determined attacker can spoof the hardware UUID in a VM or with kernel
  tooling, or genuinely use many physical Macs. Negligible for a consumer screen
  tool; not worth chasing for launch.
- A legitimate second person on a genuinely shared/family Mac is blocked (the
  cost of "hard block"). We expose a support path (§7) and measure how often it
  fires (§9) so we can revisit if it's noisy.

## 3. The device identifier

### What to read

Primary: the IOKit platform UUID from `IOPlatformExpertDevice`
(`kIOPlatformUUIDKey`). Stable per machine, readable without entitlement or
permission, survives app delete + reinstall (it's hardware, not app state).

```swift
// apps/desktop/Zerro/Services/Managed/DeviceIdentity.swift  (new file)
import Foundation
import IOKit

enum DeviceIdentity {
    /// SHA-256 hex of (platformUUID + appSalt). Never returns the raw UUID.
    /// nil only when the hardware UUID is unreadable (extremely rare on real Macs).
    static func hashedDeviceID() -> String? {
        guard let uuid = platformUUID() else { return nil }
        return sha256Hex(uuid + Self.salt)
    }

    private static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,                       // macOS 12+; target is 15+
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return (cf.takeRetainedValue() as? String)
    }

    // Compile-time pepper so a leaked DB hash can't be matched against a known
    // UUID by anyone who doesn't have the binary. Not a secret store — just
    // raises the bar. Keep it constant forever (changing it re-keys every device).
    private static let salt = "<<embed a fixed random string at build>>"
}
```

### Rules

- **Hash client-side, never send the raw UUID.** The server only ever sees
  `device_id_hash` (SHA-256 hex). The DB never holds a raw hardware identifier.
- **One-way only.** No reversing, no analytics use. Used solely for the
  one-grant-per-device cap.
- **Fallback when unreadable:** if `hashedDeviceID()` is nil (rare), the app
  omits the field and the server degrades to the existing email-only cap for
  that request, and logs it. We do **not** fail the trial over a missing device
  ID — that would punish legitimate users for a hardware read quirk.
- **No permission ordering issue:** reading the platform UUID needs no TCC
  grant, so it works during onboarding *before* the screen-recording step.

### Privacy / compliance

- Disclose in the privacy policy: "We collect a one-way hash of a hardware
  identifier to prevent trial abuse." This is standard fraud-prevention
  processing.
- The hash is pseudonymous and already covered by the per-customer delete flow
  if we attach it to the grant row (deleting the grant deletes the hash).

## 4. Backend changes

### 4.1 Schema migration — `trial_grants.device_id_hash`

New migration, e.g. `supabase/migrations/20260619120000_trial_device_binding.sql`:

```sql
alter table public.trial_grants
  add column if not exists device_id_hash text;

comment on column public.trial_grants.device_id_hash is
  'SHA-256(hardware UUID + app salt) of the Mac that created this trial. One
   grant per device (partial unique index below). Nullable: old rows and rare
   unreadable-UUID clients stay NULL and fall back to the email-only cap.';

-- The hard one-grant-per-device cap, race-safe at the DB level. Partial so many
-- NULLs (unreadable-UUID clients) never collide with each other.
create unique index if not exists trial_grants_device_id_hash_key
  on public.trial_grants (device_id_hash)
  where device_id_hash is not null;
```

Pre-launch note: `trial_grants` holds only test data, so **no backfill is
needed** — optionally truncate test grants so dev machines aren't pre-burned.

### 4.2 `verify_trial_grant` — enforce one-per-device at the single writer

`verify_trial_grant` is already the only writer of `trial_grants`. Extend it to
take the device hash and make it the atomic enforcement point. New behavior:

1. If `p_device_id_hash` is non-null **and** a grant already exists for that
   device under a **different** email → return a "device used" sentinel
   (e.g. `grant_id = NULL`), do not create anything.
2. Otherwise upsert by `email_normalized` exactly as today (create-once,
   never reset credits), and set `device_id_hash` on first create.
3. The partial unique index is the race backstop: two concurrent verifies with
   the same device + different emails → one wins, the other raises
   `unique_violation`, which the function catches and maps to the same "device
   used" sentinel.

```sql
create or replace function public.verify_trial_grant(
  p_email          text,
  p_limit          integer,
  p_device_id_hash text default null            -- new, defaulted for back-compat
)
returns table(grant_id uuid, credits_remaining integer)
language plpgsql
as $$
declare
  v_id uuid; v_used int; v_limit int;
begin
  -- (1) device already burned by a DIFFERENT email → hard block.
  if p_device_id_hash is not null then
    perform 1 from public.trial_grants
      where device_id_hash = p_device_id_hash
        and email_normalized <> p_email;
    if found then
      grant_id := null; credits_remaining := 0; return next; return;
    end if;
  end if;

  -- (2) create-once / never-reset by email (unchanged), stamping the device.
  begin
    insert into public.trial_grants
      (email_normalized, verified_at, trial_credits_limit, trial_credits_used, device_id_hash)
    values (p_email, now(), p_limit, 0, p_device_id_hash)
    on conflict (email_normalized) do update
      set verified_at    = coalesce(public.trial_grants.verified_at, now()),
          device_id_hash = coalesce(public.trial_grants.device_id_hash, excluded.device_id_hash)
    returning id, trial_credits_used, trial_credits_limit
      into v_id, v_used, v_limit;
  exception when unique_violation then
    -- (3) race: device index lost the insert → same hard block.
    grant_id := null; credits_remaining := 0; return next; return;
  end;

  grant_id := v_id;
  credits_remaining := greatest(0, v_limit - v_used);
  return next;
end;
$$;
```

Caller (`store.ts → verifyGrant`) treats `grant_id = null` as the new
`device_trial_used` outcome (distinct from a normal exhausted grant).

### 4.3 `trial-start` edge function — accept + check the device hash

`supabase/functions/trial-start/`:

- **`store.ts`**
  - `TrialStore.verifyGrant` gains a `deviceIdHash: string | null` arg and passes
    `p_device_id_hash` to the RPC; returns a `deviceBlocked: true` discriminant
    when the RPC yields a null `grant_id`.
  - Add `deviceAlreadyGranted(deviceIdHash): Promise<boolean>` — a cheap read
    used by the `request` early-block (below): does any grant exist for this
    device under a different email than the one being requested?

- **`handler.ts`**
  - Read `device_id_hash` from the request body (optional; tolerate missing).
  - **`request`:** after the existing email/disposable checks, if a device hash
    is present and `deviceAlreadyGranted` is true → return
    `{ status: "device_trial_used" }` **before** generating/emailing a code
    (saves mail + gives instant UX).
  - **`verify`:** pass the device hash into `verifyGrant`; on `deviceBlocked`
    return `{ status: "device_trial_used" }` (HTTP 200, like `already_used`).
  - **`resume`:** unchanged in logic (it grants nothing new and is email-keyed),
    but accept + forward the device hash for telemetry only.
  - Emit a structured log + PostHog event on every device block (§9).

- **`config.ts`:** no new tunable required. Optionally add
  `TRIAL_DEVICE_BINDING_ENABLED` (default true) as a kill switch so the cap can
  be disabled via `supabase secrets set` without an app release if it ever
  misfires at launch.

No change to the trial token, `/generate`, or `/entitlement` — the grant id the
token carries is unchanged.

## 5. Desktop app changes

`apps/desktop/Zerro/Services/Managed/`:

- **New `DeviceIdentity.swift`** (§3) — reads + hashes the platform UUID.
- **`TrialCreditsManager.swift`**
  - `postTrialStart(_:)` injects `device_id` into the payload when
    `DeviceIdentity.hashedDeviceID()` is non-nil. The payload is already
    `[String: String]`, so this is a one-line add to `requestCode`, `verifyCode`,
    and `performResume` call sites (or, cleaner, inside `postTrialStart` itself
    so all three get it automatically).
  - `mapError` / `TrialStartError`: add a `deviceTrialUsed` case mapping the
    `device_trial_used` status, with user copy distinct from `alreadyUsed`
    (e.g. "This Mac has already used its free trial. Upgrade to keep going.").
  - `requestCode` and `verifyCode`: handle the new status the same way they
    handle `already_used` today (throw the typed error; the capture sheet
    renders it).
- **UI copy** — `Surfaces/TrialEmail/TrialEmailCaptureView.swift` and
  `Surfaces/Onboarding/OnboardingSteps.swift`: render the device-used message
  and route the user to the paywall (`PaywallView`) instead of a dead end.
- **DEBUG reset** — `apps/desktop/reset-for-testing.sh` and the in-app DEBUG
  reset are local-only; they will **not** clear the server device grant
  (correct — that's the whole point). Add a documented backend test path
  (a SQL snippet or a dev-only `device_id_hash` reset) for QA so testers aren't
  permanently burned on their dev Macs.

## 6. Enforcement semantics (the truth table)

| Device seen before? | Email seen before? | Outcome |
|---|---|---|
| no | no | new grant (40 credits) |
| no | yes (same email) | resume same grant, same remaining balance |
| yes | yes (same email) | resume same grant (legit reinstall on same Mac) |
| **yes** | **no (new email)** | **hard block → `device_trial_used`** |
| device unreadable (null) | — | falls back to email-only cap (status quo) + logged |

The only new "no" is the bolded row — exactly the attack we're closing.

## 7. Shared-machine support path

Because strictness is "hard block", a genuine second user on a shared Mac will
hit `device_trial_used`. Mitigations:

- Clear copy: "already used on this Mac" + an upgrade button, not a generic
  error.
- A support route (email link in the message) so we can manually clear a
  device hash for a verified legitimate case. Keep a tiny internal runbook:
  `delete from trial_grants where device_id_hash = $1` (or null the column) for
  the specific device after verifying the request.

## 8. Rollout / sequencing

1. Migration: add column + partial unique index (safe, additive).
2. Deploy `verify_trial_grant` change (new defaulted arg → backward compatible
   with the current function callers).
3. Deploy `trial-start` function changes (tolerates missing `device_id`, so it's
   safe to ship before the app update).
4. Ship the app update that sends `device_id`.
5. (Optional) Truncate test grants so dev/test machines start clean.

Because steps 1–3 tolerate a missing device hash, there's no flag-day coupling
between the backend and the app release. Old app builds keep working on the
email-only cap; new builds get the device cap.

Kill switch: `TRIAL_DEVICE_BINDING_ENABLED=false` disables the block at the
backend without an app release if it misfires at launch.

## 9. Telemetry (measure abuse + false positives)

Emit a PostHog event from `trial-start` on every device block:
`trial_device_block` with properties `{ phase: "request"|"verify", reason }`
(hashed device id only, never email/raw UUID — consistent with §14.5's
tier-only analytics rule). This tells us:

- how much farming we're actually stopping (volume), and
- whether legitimate shared-machine users are hitting it (support correlation),
  so the hard-block decision stays data-informed.

## 10. Testing

- **Unit (handler, in-memory store):** new-device new-email → grant;
  known-device new-email → `device_trial_used` at both `request` and `verify`;
  known-device same-email → resume; null device hash → email-only behavior
  unchanged. Extend `handler_test.ts`.
- **SQL (`verify_trial_grant`):** concurrent verify, same device + two emails →
  exactly one grant, the other blocked (proves the partial unique index +
  exception path). Add to `supabase/test`.
- **Swift:** `DeviceIdentity.hashedDeviceID()` returns stable non-nil hex on a
  real Mac; `TrialCreditsManager` injects `device_id` and maps the new status to
  `deviceTrialUsed`. Use the existing injectable `ManagedTransport` stub.
- **Manual matrix:** fresh email on a Mac that already trialed → blocked at the
  email step (no code email sent); reinstall + same email → resumes; second
  distinct email after reinstall → blocked.

## 11. Optional future hardening (not for launch)

- **Card-on-file to start the trial** (via LemonSqueezy) — the strongest
  deterrent, but real funnel friction; revisit only if device binding leaves
  meaningful abuse in the data.
- Maintained disposable-domain list (swap the static set for a refreshed feed).
- Lifetime per-IP grant cap (in addition to the existing windowed rate limit) —
  cheap, but watch shared-NAT false positives.

---

### File-change checklist

- `supabase/migrations/20260619120000_trial_device_binding.sql` — new
- `supabase/migrations/…verify_trial_grant…` (or apply via MCP migration) — alter function
- `supabase/functions/trial-start/store.ts` — `verifyGrant` arg + `deviceAlreadyGranted`
- `supabase/functions/trial-start/handler.ts` — read/check device hash, new status, telemetry
- `supabase/functions/trial-start/handler_test.ts` — new cases
- `supabase/functions/trial-start/config.ts` — optional kill-switch flag
- `apps/desktop/Zerro/Services/Managed/DeviceIdentity.swift` — new
- `apps/desktop/Zerro/Services/Managed/TrialCreditsManager.swift` — inject device_id, new error
- `apps/desktop/Zerro/Surfaces/TrialEmail/TrialEmailCaptureView.swift` — copy + paywall route
- `apps/desktop/Zerro/Surfaces/Onboarding/OnboardingSteps.swift` — copy + paywall route
- privacy policy — disclose hashed hardware identifier for fraud prevention
