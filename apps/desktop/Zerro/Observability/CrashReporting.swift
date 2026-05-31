//
//  CrashReporting.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Phase 13 (Part B) — single owner of the Sentry SDK lifecycle.
//
//  Why a single chokepoint
//  -----------------------
//  Sentry is the SOLE place in Zerro that ever transmits anything off the
//  user's machine other than the frames they explicitly chose to send to
//  their own BYOK API. Everything that flows through it does so via
//  `beforeSend` / `beforeBreadcrumb` in this file. There is no other call
//  site for `SentrySDK.start` or for those two options — search for them
//  and you should find exactly one match each, here.
//
//  Privacy contract (enforced by C3, in `start()`):
//    • `sendDefaultPii = false` — no IP, no user identifier. The Sentry
//      onboarding default is `true`; we override it explicitly.
//    • `tracesSampleRate = 0` — crash reporter only. No APM.
//    • No screenshot / view-hierarchy / session-replay attachment. (Those
//      APIs are iOS-only on 9.x today and so are not even set here; if
//      Sentry ever adds macOS equivalents an explicit `false` MUST be
//      added before the next release. See note below where they'd go.)
//    • `beforeSend` scrubs `message`, exception values, and `extra`/
//      breadcrumb data before any event leaves the process.
//    • `beforeBreadcrumb` is an allowlist — only operational categories
//      we emit deliberately survive; anything else (e.g. auto HTTP
//      breadcrumbs that could carry URLs with query strings) is dropped.
//    • The user-facing "Send anonymous crash reports" toggle (C5) gates
//      everything: when OFF, `beforeSend` returns `nil` and nothing
//      leaves the machine, taking effect immediately without an app
//      restart.
//
//  DSN supply: read from the `SENTRY_DSN` Info.plist key (C3). Missing
//  or empty value short-circuits `start()` — the app runs normally with
//  no crash reporting, with one NSLog line on launch.
//

import Foundation
import os
import Sentry

enum CrashReporting {

    // MARK: - Last event ID tracking
    //
    // The Sentry Cocoa SDK (unlike the Android / JS SDKs) does NOT
    // expose a `SentrySDK.lastEventId` accessor. To support the C6
    // "Copy diagnostic info" bridge we capture it ourselves on every
    // event that survives `beforeSend` (handled OR crash), behind an
    // OSAllocatedUnfairLock because `beforeSend` can be invoked on a
    // background thread.

    private static let lastEventIdLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    private static func recordLastEventId(_ id: SentryId) {
        let s = id.sentryIdString
        guard s != "00000000000000000000000000000000" else { return }
        lastEventIdLock.withLock { $0 = s }
    }

    // MARK: - User preference (C5)

    /// UserDefaults key that backs the Settings "Send anonymous crash
    /// reports" toggle. Defined here (not on PreferencesStore) so this
    /// helper has no dependency on SwiftUI / the prefs store and can
    /// be read from `beforeSend` on any thread.
    ///
    /// Default value: ON. The toggle row in AppBehaviorSection writes to
    /// this same key via @AppStorage with the same default.
    static let isEnabledDefaultsKey = "crashReporting.isEnabled"

    /// Re-read on every event so flipping the toggle takes effect
    /// immediately, without an app restart. Treats key-absent as ON
    /// (the default); only an explicit `false` disables reporting.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: isEnabledDefaultsKey) as? Bool ?? true
    }

    // MARK: - Lifecycle (C2)

    /// Idempotent. Called once from `ZerroApp.init`'s one-shot bootstrap
    /// block; this static flag protects against SwiftUI re-invoking the
    /// App initializer (same pattern as `didRegisterGlobalShortcuts`).
    private static var didStart = false

    static func start() {
        guard !didStart else { return }
        didStart = true

        guard let dsn = readDSN(), !dsn.isEmpty else {
            NSLog("[CrashReporting] SENTRY_DSN missing or empty in Info.plist — crash reporting disabled this launch.")
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn

            // ---- Release attribution ----
            options.releaseName = Self.releaseName()
            options.environment = Self.environment()

            // ---- PRIVACY HARDENING (C3) ----

            // Explicit override of the Sentry onboarding default
            // (which is `true` and would attach the user's IP plus
            // other identifying data). Zerro is local-first; the
            // crash reporter must be anonymous.
            options.sendDefaultPii = false

            // No performance tracing for v1. Crash reporter only.
            // DEFERRED: revisit tracing if needed.
            options.tracesSampleRate = 0

            // Catch main-thread stalls (a sync permissions call
            // blocking, the recording focus pill freezing, etc.).
            // App-hang detection reports stack frames, not user
            // content, so it's privacy-safe.
            options.enableAppHangTracking = true

            // Crash handler stays on. Default is true; stated here
            // for documentation rather than effect.
            options.enableCrashHandler = true

            // Anonymous session tracking powers Sentry's crash-free-
            // session metric; keep on.
            options.enableAutoSessionTracking = true

            // Debug log only in DEBUG builds.
            #if DEBUG
            options.debug = true
            #else
            options.debug = false
            #endif

            // ⚠️ SCREENSHOT / VIEW-HIERARCHY / SESSION-REPLAY ⚠️
            //
            // These options exist on iOS in 9.x but are NOT exposed
            // on macOS today, so setting `options.attachScreenshot
            // = false` here would not compile. If Sentry ever adds
            // a macOS variant of ANY of:
            //   • options.attachScreenshot
            //   • options.attachViewHierarchy
            //   • options.experimental.sessionReplay
            // an explicit `false` MUST be added in this block before
            // the next release — the screen could contain anything
            // the user is recording, transcripts, or generated prompt
            // text. Treat the presence of a new screen-capture option
            // as a privacy-review gate.

            // ---- REDACTION BOUNDARY: beforeSend ----
            //
            // Every event passes through this closure before it leaves
            // the process. Three jobs, in order:
            //   1. Honor the user-facing toggle. `nil` = drop.
            //   2. Strip free-form text fields that could carry user
            //      content (event.message, exception values, extras,
            //      breadcrumb messages/data).
            //   3. Defense in depth — even if beforeBreadcrumb already
            //      filtered, `scrub` re-walks breadcrumbs on the event.
            options.beforeSend = { event in
                guard Self.isEnabled else { return nil }
                Self.scrub(event)
                // Record AFTER scrub so we never expose an ID for an
                // event that won't actually ship. `event.eventId` is
                // populated by the SDK before beforeSend fires.
                Self.recordLastEventId(event.eventId)
                return event
            }

            // ---- REDACTION BOUNDARY: beforeBreadcrumb ----
            //
            // Allowlist-only. Default-drop anything we don't
            // explicitly recognize as safe, operational telemetry.
            // The Sentry SDK auto-instruments categories like "http"
            // and "network" — those can contain URLs with query
            // strings, so they're dropped. We don't emit any
            // breadcrumbs ourselves yet; once we do (Phase 13 —
            // logging task), the categories belong in
            // `allowedBreadcrumbCategories` below.
            options.beforeBreadcrumb = { crumb in
                guard Self.isEnabled else { return nil }
                return Self.allowlistedOrNil(crumb)
            }
        }
    }

    // MARK: - Manual capture (C4)

    /// Capture a handled, non-fatal error with a developer-supplied
    /// label and safe operational context.
    ///
    /// CALL-SITE RULES — privacy contract, enforced where possible by
    /// the Swift type system:
    ///
    /// • `message` is `StaticString`. Swift only lets a STRING LITERAL
    ///   bind to `StaticString` at the call site — interpolated
    ///   strings, `error.localizedDescription`, API response bodies,
    ///   file paths, and anything else derived from runtime data
    ///   will FAIL TO COMPILE here. This is the mechanical enforcement
    ///   of "never let user content into the event label". Make the
    ///   literal descriptive — it becomes a searchable tag in the
    ///   Sentry dashboard ("Processing pipeline failed",
    ///   "Prompt generation failed", etc.).
    ///
    /// • `context` keys must be in `allowedContextKeys`. Unknown keys
    ///   are silently dropped by `scrubContext`; values that look
    ///   secret-shaped or exceed 80 chars are also dropped. Use this
    ///   for error codes, model names, network-reachable flags,
    ///   bucketed counts — NEVER for content of any kind.
    ///
    /// • The `error` argument is captured for its stack trace and
    ///   type name. Sentry will derive `event.message` from the
    ///   error's description; `scrub()` clamps that to ≤120 chars
    ///   before transmission, but the strongest defense is to pass
    ///   typed errors whose descriptions are themselves bounded
    ///   (e.g. `ProcessingError.processingFailed`), not free-form
    ///   wrappers that interpolate paths or response bodies.
    ///
    /// `stage` is the pipeline stage label ("recording", "processing",
    /// "transcription", "promptGeneration"). It rides as a Sentry tag
    /// so failures are filterable in the dashboard.
    @discardableResult
    static func capture(
        _ error: Error,
        message: StaticString,
        stage: String,
        context: [String: String] = [:]
    ) -> SentryId? {
        guard isEnabled else { return nil }
        // `StaticString` interpolation produces the original literal,
        // bounded and safe. Stored as a Sentry tag (parallel to the
        // auto-derived event title) so the Sentry dashboard can group
        // and filter by it.
        let label = "\(message)"
        return SentrySDK.capture(error: error) { scope in
            scope.setTag(value: stage, key: "stage")
            scope.setTag(value: label, key: "label")
            for (key, value) in Self.scrubContext(context) {
                scope.setTag(value: value, key: key)
            }
        }
    }

    /// Most recent event ID that survived `beforeSend` this launch, as
    /// a string. Returned to the "Copy diagnostic info" button (C6 —
    /// Phase 13 logging task) so a support email correlates to a crash.
    /// Returns `nil` if no event has been sent yet this launch (or if
    /// `beforeSend` is dropping events because the user toggled crash
    /// reporting OFF).
    static var lastEventId: String? {
        lastEventIdLock.withLock { $0 }
    }

    // MARK: - Scrubbing internals

    /// Mutates the event in place to strip every field that could carry
    /// user content. Conservative: any field we don't explicitly
    /// understand to be safe is cleared, not edited.
    private static func scrub(_ event: Event) {
        // 1. Top-level message. Clamped (not wiped) so a developer
        //    `capture(message:)` literal survives for triage. The
        //    StaticString constraint on `capture()` already prevents
        //    runtime data from entering this field via that path; this
        //    clamp is the belt-and-braces guard for any OTHER path
        //    (SDK auto-derivation from an error description that
        //    might embed a path or content) — and matches the 120-char
        //    bound used for breadcrumbs below.
        if let msg = event.message, msg.formatted.count > 120 {
            event.message = SentryMessage(formatted: String(msg.formatted.prefix(120)) + "…")
        }

        // 2. Exceptions: keep the type (which is what tells us what
        //    actually broke) but cap the `value` length. Swift error
        //    descriptions are typically short like
        //    "OpenAIClient.Error.auth"; the truncate is a belt-and-
        //    braces against an `error.localizedDescription` path that
        //    embeds file contents.
        if let exceptions = event.exceptions {
            for ex in exceptions {
                if let value = ex.value, value.count > 200 {
                    ex.value = String(value.prefix(200)) + "…"
                }
            }
        }

        // 3. Extras / context: drop wholesale. Safe context flows
        //    through `tags` via `scrubContext`, never through extras.
        //    If the SDK auto-attached anything (debug context, etc.),
        //    blow it away to stay safe.
        event.extra = nil

        // 4. Breadcrumb safety net (defense in depth — the
        //    beforeBreadcrumb allowlist should already have caught
        //    these): scrub data and bound message length on every
        //    breadcrumb that made it onto the event.
        if let crumbs = event.breadcrumbs {
            for crumb in crumbs {
                crumb.data = nil
                if let msg = crumb.message, msg.count > 120 {
                    crumb.message = String(msg.prefix(120))
                }
            }
        }

        // 5. User object. The Sentry Cocoa SDK auto-attaches an
        //    installation UUID as `event.user.id` even when
        //    `sendDefaultPii = false` — it's anonymous (not real
        //    user info) but is a stable pseudonymous identifier
        //    across launches. Zerro's "no telemetry" posture is
        //    stronger than that allows, so drop the user object
        //    entirely. Cost: the dashboard's "Users" column will
        //    no longer be meaningful (every event reads as one
        //    unknown user); acceptable trade for the brand promise.
        event.user = nil

        // 6. Debug image list. The SDK auto-attaches the loaded
        //    image list (`event.debugMeta`), one entry per dylib
        //    with its full on-disk `codeFile` path. In DEBUG that
        //    path includes the user's macOS short name
        //    (`/Users/<name>/Library/Developer/Xcode/DerivedData/…`);
        //    in RELEASE it's `/Applications/Zerro.app/…` if the
        //    user installed normally but a custom install location
        //    would leak its path too. Clamp every `codeFile` to
        //    just its basename — Sentry symbolicates against the
        //    image UUID (`debugID`), not the path, so we keep
        //    full symbolication ability while transmitting nothing
        //    about the filesystem layout.
        if let images = event.debugMeta {
            for image in images {
                if let path = image.codeFile {
                    image.codeFile = (path as NSString).lastPathComponent
                }
            }
        }
    }

    /// Allowlist for the `context` dict callers pass to `capture()`.
    /// Restricting keys to a known set means a typo on a call site
    /// can't slip user content through; values are additionally
    /// dropped if they look secret-shaped or unusually long.
    private static let allowedContextKeys: Set<String> = [
        "errorCode",            // typed error case, e.g. "auth"
        "modelName",            // "gpt-4o", "whisper-1" — never the key
        "networkReachable",     // "true" / "false"
        "frameCount",           // integer as string
        "durationSecondsBucket" // bucketed, not raw seconds
    ]

    private static func scrubContext(_ ctx: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in ctx {
            guard allowedContextKeys.contains(key) else { continue }
            guard !looksLikeSecret(value), value.count <= 80 else { continue }
            out[key] = value
        }
        return out
    }

    private static func looksLikeSecret(_ s: String) -> Bool {
        // OpenAI keys start with "sk-"; generic high-entropy tokens
        // tend to be long alphanumerics. Cheap heuristic — if a value
        // matches, it's dropped.
        if s.hasPrefix("sk-") { return true }
        if s.count >= 32 && s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
            return true
        }
        return false
    }

    // MARK: - Breadcrumb allowlist

    /// Categories we emit deliberately. Auto-instrumentation categories
    /// like "http" / "network" are NOT here and are therefore dropped
    /// by `beforeBreadcrumb`. We don't emit breadcrumbs ourselves yet;
    /// once we do (Phase 13 — logging task), names belong here.
    private static let allowedBreadcrumbCategories: Set<String> = [
        "appLifecycle",
        "stateMachine",
        "pipelineStage",
        "permissionChange"
    ]

    private static func allowlistedOrNil(_ crumb: Breadcrumb) -> Breadcrumb? {
        // `crumb.category` is non-optional `String` in Sentry 9.x
        // Cocoa — checked directly, not via optional binding.
        guard allowedBreadcrumbCategories.contains(crumb.category) else {
            return nil
        }
        // Even on allowed categories, scrub free-form data and bound
        // the message length: the allowlist controls which SUBSYSTEMS
        // can speak; this controls what they can SAY.
        crumb.data = nil
        if let msg = crumb.message, msg.count > 120 {
            crumb.message = String(msg.prefix(120))
        }
        return crumb
    }

    // MARK: - Release / environment

    private static func releaseName() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundleID = info["CFBundleIdentifier"] as? String ?? "com.zerro.app"
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        // Sentry convention: "<package>@<version>+<build>".
        return "\(bundleID)@\(version)+\(build)"
    }

    private static func environment() -> String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    // MARK: - DSN

    private static func readDSN() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String
    }
}
