# Handoff: Capture provider-returned generation errors in PostHog error tracking

## Context / why

When a managed or trial recording generation fails, the app **always** fires the
`generation_failed` analytics event, but it only sends an `$exception` to PostHog
**error tracking** when `AppState.shouldCapture(_:)` returns `true`. Today every
provider-side failure (5xx, 429, 422) returns `false`, so those failures are
invisible in error tracking.

Concrete case this came from: a `POST /generate` returned **503 after ~120 s**
(upstream `gpt-5.5` unavailable). The user saw "Generation failed", retried, and
it succeeded — but nothing reached error tracking because `providerUnavailable`
is gated out. We confirmed this in PostHog (`generation_failed` event with
`reason=providerUnavailable`) and in the Supabase edge logs (the 503).

We now want these provider-returned errors recorded in error tracking, **with
enough detail to triage** (HTTP status + a short server message), and **grouped**
so a provider outage collapses into one issue instead of flooding the dashboard.

## Goal (agreed scope)

1. Start capturing these `RecordingFailureReason` cases in error tracking:
   - `.providerUnavailable` (proxy/provider 5xx, incl. 502/503)
   - `.rateLimited` (429)
   - `.responseTooLong` (422 output-token truncation)
2. **Keep excluding** `.networkOffline` (local connectivity, not a provider
   response) and all billing/entitlement reasons (`.outOfCredits`,
   `.outOfCreditsAtStart`, `.subscriptionInactive`, `.trialVerificationRequired`,
   `.trialCreditsExhausted`). Do not change those.
3. Preserve and attach the **HTTP status code** and a **bounded server error
   message** so issues are triageable rather than the current useless
   `ManagedGenerationError error 0`.
4. Set a custom `$exception` **fingerprint** so all events of the same
   `reason` + `status` group into a single error-tracking issue (flood control).
5. Leave the existing `generation_failed` analytics event exactly as-is. This is
   purely additive to the error-tracking path.

## Important distinction before you start

There are **two different enums** — do not confuse them:

- `RecordingFailureReason` (in `AppState.swift`) is **value-less** and is switched
  over in many places (`isRetryable`, `headline`, copy, `shouldCapture`,
  `errorCodeString`). **Keep it value-less** — do NOT add associated values here,
  or you'll have to touch every one of those switches.
- `ManagedGenerationError` (in `ManagedProxyClient.swift`) is the wire-level error
  that DOES carry detail. This is where the status code + body live (or rather,
  where they currently get thrown away). Associated values go here.

## Current code (read these first)

- `apps/desktop/Zerro/AppState.swift`
  - `RecordingFailureReason` enum — declared at **line 157** (value-less; leave as-is).
  - The managed/trial generation **catch block** — **lines 2384–2403**. This is
    the single capture site to extend (it captures `error`, fires the analytics
    event, then gates `CrashReporting.capture` behind `shouldCapture`).
  - `managedFailureReason(from:)` — **line 2585** (switches over
    `ManagedGenerationError`; will need pattern updates after you add associated
    values).
  - `shouldCapture(_:)` — **line 3844** (the gate to flip).
  - `errorCodeString(_:)` — **line 3868** (`String(describing: reason)`; unchanged).
  - `failureDetail(from:)` — **line 3902** (switches over `ManagedGenerationError`
    for the user-facing card; needs pattern updates; keep its output privacy-safe).
- `apps/desktop/Zerro/Services/Managed/ManagedProxyClient.swift`
  - `ManagedGenerationError` enum — **line 51**. `providerUnavailable` carries
    **no** detail today.
  - `parse(data:status:)` — **lines ~584–603**: `case 500...599` and `default`
    throw `.providerUnavailable` and **discard** `status` and the response `data`.
    `case 429` → `.rateLimited`, `case 422` → `.responseTruncated`.
  - `parseTranscribe(data:status:)` — **lines ~610–634**: same taxonomy for Dev
    Mode call 1; update consistently.
- `apps/desktop/Zerro/Observability/CrashReporting.swift`
  - `capture(_:message:stage:context:)` — **line 85**. `message` is a
    `StaticString` (privacy: literals only). `context` is `[String: String]` and
    is **allowlisted + scrubbed**: keys must be in `allowedContextKeys`
    (**line 113**), and values are **dropped if secret-shaped or > 80 chars**
    (`scrubContext`, line 121).

## Implementation steps

### 1. Carry status + body on the provider error (`ManagedProxyClient.swift`)

Add associated values to the provider-origin cases so the status code and a
**pre-truncated** server message survive up to the capture site. Suggested shape:

```swift
case rateLimited(status: Int, body: String?)
case providerUnavailable(status: Int, body: String?)
// responseTruncated is always HTTP 422; either add (status:body:) for symmetry
// or leave value-less and let the capture site default status to 422.
```

`ManagedGenerationError` is `Equatable`; `Int`/`String?` payloads keep it
`Equatable`, but **find and update every `switch` over this enum** (at minimum
`managedFailureReason` and `failureDetail`, plus any tests).

In `parse` / `parseTranscribe`, populate them — and **truncate the body to ≤ 80
chars here** (the `CrashReporting` scrubber drops anything longer, so truncating
at the throw site is what keeps it):

```swift
case 429:
    throw ManagedGenerationError.rateLimited(status: status, body: Self.shortBody(data))
case 500...599:
    throw ManagedGenerationError.providerUnavailable(status: status, body: Self.shortBody(data))
default:
    throw ManagedGenerationError.providerUnavailable(status: status, body: Self.shortBody(data))
```

Add a small private helper, e.g.:

```swift
/// First line of the server body, collapsed + capped for safe telemetry.
/// Never transcript/response content — this is the error path only.
private static func shortBody(_ data: Data) -> String? {
    guard let s = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    return String(s.prefix(80))
}
```

`managedFailureReason(from:)` keeps returning the same value-less
`RecordingFailureReason` cases — just update its `case` patterns to ignore the new
payloads, e.g. `case .providerUnavailable: return .providerUnavailable` becomes
`case .providerUnavailable: return .providerUnavailable` with the pattern
`case .providerUnavailable(_, _):`.

### 2. Flip the gate (`AppState.shouldCapture`, line 3844)

Move `.providerUnavailable`, `.rateLimited`, and `.responseTooLong` into the
`return true` group. Leave `.networkOffline` and all billing/entitlement cases in
the `return false` group. Update the comment to explain that provider 5xx/429/422
are now intentionally captured (and grouped via fingerprint — see step 4).

### 3. Pass provider detail at the capture site (`AppState.swift`, ~2384–2403)

Add a helper that extracts `(status, body)` from the `error` when it's a
provider-origin `ManagedGenerationError`, and feed them into the `context` dict.
Works for both the managed and trial branches (both go through this catch):

```swift
if Self.shouldCapture(reason) {
    var ctx = ["errorCode": Self.errorCodeString(reason)]
    if let (status, body) = Self.providerHTTPDetail(from: error) {
        ctx["providerStatus"] = String(status)
        if let body { ctx["providerMessage"] = body }   // already ≤80 from step 1
    }
    CrashReporting.capture(
        error,
        message: "Proxy generation failed",   // keep as a StaticString literal
        stage: "proxyGeneration",
        context: ctx,
        fingerprint: ["proxyGeneration", Self.errorCodeString(reason),
                      Self.providerHTTPDetail(from: error).map { String($0.status) } ?? "na"]
    )
}
```

`providerHTTPDetail` returns `(status: Int, body: String?)?` by switching over the
new `ManagedGenerationError` payloads (return `nil` for non-provider errors;
default `responseTruncated` to status `422` if you left it value-less).

### 4. Allowlist + fingerprint (`CrashReporting.swift`)

- Add `"providerStatus"` and `"providerMessage"` to `allowedContextKeys`
  (line 113). They still pass through `scrubContext` (≤80 chars, non-secret), so
  step 1's truncation matters.
- Add a `fingerprint` parameter to `capture(...)` and apply it. PostHog supports a
  custom grouping key via the `$exception_fingerprint` property — **verify the
  exact key/shape for the current `posthog-ios` SDK version** (check
  `Package.resolved` / PostHog iOS error-tracking docs) before wiring it:

```swift
static func capture(
    _ error: Error,
    message: StaticString,
    stage: String,
    context: [String: String] = [:],
    fingerprint: [String]? = nil
) -> String? {
    ...
    if let fingerprint { properties["$exception_fingerprint"] = fingerprint }
    PostHogSDK.shared.captureException(error, properties: properties)
    ...
}
```

If `$exception_fingerprint` isn't honored by the installed SDK version, fall back
to a PostHog **grouping rule** in the project UI keyed on the `stage` +
`errorCode` + `providerStatus` properties, and note that in the PR.

## Privacy contract (do not break)

- `message` stays a **`StaticString` literal** — never interpolate runtime data.
- Only safe operational values in `context`: status code, short error message,
  error code. **Never** transcript or model response content. The `shortBody`
  helper is the error-path body only and is capped at 80 chars + scrubbed.
- Don't widen `allowedContextKeys` beyond the two new keys.

## Acceptance criteria

1. Forcing the proxy to return 503 (or pointing the client at a stubbed 503)
   produces a PostHog `$exception` with `stage=proxyGeneration`,
   `errorCode=providerUnavailable`, `providerStatus=503`, and a readable label —
   not `ManagedGenerationError error 0`.
2. A 429 and a 422 likewise produce captured exceptions with the right
   `errorCode` (`rateLimited`, `responseTooLong`) and `providerStatus`.
3. `.networkOffline` and all billing/entitlement failures still produce **no**
   exception (only the `generation_failed` analytics event).
4. The `generation_failed` analytics event is unchanged (same props/values).
5. Repeated identical provider failures group into a **single** error-tracking
   issue (fingerprint working), verified in the PostHog UI.
6. No transcript/response content appears in any captured property.

## Testing notes

- Analytics + error tracking are **disabled in DEBUG builds** and gated on the
  "Send Anonymous Usage Data & Crash Reports" toggle (`Analytics.start`,
  `Analytics.isEnabled`). Verify end-to-end with a **release/TestFlight** build (or
  temporarily allow capture in DEBUG) — a plain `Run` from Xcode won't send.
- Unit-test the new `parse` mappings (429/422/5xx → correct case **with** status +
  truncated body) and `providerHTTPDetail` / `shortBody` (truncation, nil on
  empty, nil for non-provider errors).
- After release, confirm in PostHog: a new error-tracking issue appears for a real
  `providerUnavailable`, and the `generation_failed` event volume is unchanged.

## Out of scope

- Server-side (`/generate` edge function) changes.
- Changing retry/idempotency behavior.
- Capturing `.networkOffline` or billing/entitlement reasons.
