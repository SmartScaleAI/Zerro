//
//  CrashReporting.swift
//  Zerro
//
//  Created by Colin Breeding on 5/30/26.
//
//  Error tracking — now backed by PostHog (migrated off Sentry so all
//  analytics and logging live in one place).
//
//  This type is a thin, privacy-enforcing wrapper over PostHog's
//  exception capture. The SDK lifecycle (and crash autocapture) is owned
//  by `Analytics`; this file owns the HANDLED-error path and the same
//  call-site privacy contract the app already relied on. The public API
//  is unchanged from the Sentry era so existing call sites compile as-is:
//
//      CrashReporting.start()                         // → Analytics.start()
//      CrashReporting.capture(error, message:, stage:, context:)
//      CrashReporting.lastEventId
//      CrashReporting.isEnabled / .isEnabledDefaultsKey
//
//  Privacy contract (unchanged):
//    • `message` is `StaticString` — only a string LITERAL binds at the
//      call site, so interpolated runtime data (paths, response bodies,
//      `error.localizedDescription`) cannot enter the event label. It
//      becomes a searchable property in PostHog ("Prompt generation
//      failed", etc.).
//    • `context` keys must be in `allowedContextKeys`; values that look
//      secret-shaped or exceed 80 chars are dropped. Error codes, model
//      names, bucketed counts — NEVER content.
//    • The `error` is captured for its type + stack trace. Crash
//      autocapture (Mach/POSIX/NSException) is configured in `Analytics`.
//    • Gated by the user toggle via `Analytics.isEnabled` / opt-out.
//

import Foundation
import os
import PostHog

enum CrashReporting {

    // MARK: - User preference

    /// UserDefaults key backing the Settings toggle. Kept on this type
    /// (stable name `crashReporting.isEnabled`) for source compatibility:
    /// `AppBehaviorSection` reads it via @AppStorage and `Analytics`
    /// reads the same key for its opt-out gate.
    static let isEnabledDefaultsKey = "crashReporting.isEnabled"

    /// Single source of truth for the toggle. Delegates to `Analytics`
    /// so both product events and error capture honor one switch.
    static var isEnabled: Bool { Analytics.isEnabled }

    // MARK: - Last event ID (for "Copy diagnostic info")

    private static let lastEventIdLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Most recent diagnostic id attached to a captured exception this
    /// launch, surfaced by the "Copy diagnostic info" support bridge so a
    /// support email correlates to an event in PostHog (searchable as the
    /// `diagnostic_id` property). `nil` if nothing captured yet this launch.
    static var lastEventId: String? {
        lastEventIdLock.withLock { $0 }
    }

    // MARK: - Lifecycle

    /// Brings up the analytics + error-tracking backend. Idempotent.
    /// Retained as an alias so the existing `ZerroApp` call site is
    /// unchanged; the real work lives in `Analytics.start()`.
    static func start() {
        Analytics.start()
    }

    // MARK: - Manual capture of handled errors

    /// Capture a handled, non-fatal error with a developer-supplied label
    /// and safe operational context. See the privacy contract above for
    /// the call-site rules enforced here.
    ///
    /// `stage` is the pipeline stage label ("recording", "processing",
    /// "transcription", "promptGeneration") and rides as a property so
    /// errors are filterable in PostHog. Returns the generated diagnostic
    /// id (also stored as `lastEventId`), or nil when reporting is off.
    @discardableResult
    static func capture(
        _ error: Error,
        message: StaticString,
        stage: String,
        context: [String: String] = [:],
        fingerprint: [String]? = nil
    ) -> String? {
        guard isEnabled else { return nil }

        let diagnosticId = UUID().uuidString
        var properties: [String: Any] = [
            "label": "\(message)",   // StaticString → bounded, safe literal
            "stage": stage,
            "diagnostic_id": diagnosticId,
        ]
        for (key, value) in scrubContext(context) {
            properties[key] = value
        }
        // Custom error-tracking grouping. PostHog honors `$exception_fingerprint`
        // on the `$exception` event — the SDK passes additional properties
        // through verbatim (see `PostHogSDK.captureException`), so the backend
        // does the grouping. We join the caller's components into one stable key
        // so every event sharing them collapses into a single issue (e.g. one
        // provider 503 outage → one issue, flood control). A bare String is the
        // most broadly-attested shape across PostHog SDKs; we standardize on it
        // to avoid array-encoding ambiguity. Setting it takes priority over
        // PostHog's server-side grouping rules and automatic fingerprinting.
        if let fingerprint, !fingerprint.isEmpty {
            properties["$exception_fingerprint"] = fingerprint.joined(separator: ":")
        }

        PostHogSDK.shared.captureException(error, properties: properties)
        lastEventIdLock.withLock { $0 = diagnosticId }
        return diagnosticId
    }

    // MARK: - Context scrubbing

    /// Allowlist for the `context` dict callers pass to `capture()`. A typo
    /// on a call site can't slip user content through; values are also
    /// dropped if they look secret-shaped or unusually long.
    private static let allowedContextKeys: Set<String> = [
        "errorCode",            // typed error case, e.g. "auth"
        "modelName",            // "gpt-5.4-mini" — never the key
        "networkReachable",     // "true" / "false"
        "frameCount",           // integer as string
        "durationSecondsBucket", // bucketed, not raw seconds
        "providerStatus",       // provider HTTP status, e.g. "503"
        "providerMessage"       // short (≤80, scrubbed) server error message
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
        if s.hasPrefix("sk-") { return true }
        if s.count >= 32 && s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
            return true
        }
        return false
    }
}
