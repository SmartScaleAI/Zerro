//
//  Analytics.swift
//  Zerro
//
//  Single owner of the PostHog SDK lifecycle — product analytics AND
//  error tracking, consolidated into one backend (replaces Sentry).
//
//  Why a single chokepoint
//  -----------------------
//  PostHog is now the SOLE place in Zerro that transmits anything off the
//  user's machine other than the frames they explicitly send to their own
//  BYOK API. Everything flows through `capture(_:_:)` (product events) or
//  `CrashReporting.capture(...)` (handled errors), plus the SDK's own
//  crash autocapture configured in `start()`. Keep it that way: no other
//  file should call `PostHogSDK.shared.setup`.
//
//  Privacy contract
//  ----------------
//    • Gated by the user-facing "Send Anonymous Usage Data & Crash Reports"
//      toggle (same UserDefaults key as before — see CrashReporting). When
//      OFF we call `optOut()`, so nothing leaves the machine; flipping it
//      back ON calls `optIn()`. No restart required.
//    • `personProfiles = .identifiedOnly` — anonymous installs never create
//      a person profile. We never call `identify`, so every user stays
//      anonymous (a device-scoped PostHog anonymous id).
//    • NEVER pass content into an event. Properties are limited to enums,
//      counts, durations, booleans, and model ids. No prompt text, no
//      transcript text, no file paths, no email, no API keys, no hotkey
//      strings. Same discipline as the `Log` privacy qualifiers.
//    • API key + host are read from Info.plist (POSTHOG_API_KEY /
//      POSTHOG_HOST). A PostHog project key (phc_…) is client-safe, the
//      same way the old SENTRY_DSN was. Missing/placeholder key →
//      analytics is disabled this launch with one log line.
//

import Foundation
import os
import PostHog

enum Analytics {

    /// Idempotent. Called once from `ZerroApp`'s one-shot bootstrap.
    private static var didStart = false

    /// Re-reads the toggle on demand so flips take effect immediately.
    /// Key-absent → ON (the default), matching the Settings row default.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: CrashReporting.isEnabledDefaultsKey) as? Bool ?? true
    }

    /// The current anonymous PostHog `distinct_id` (a device-scoped id — we never
    /// `identify`, so it's never PII), or `nil` before `start()`. Plumbed through
    /// the LemonSqueezy checkout `custom_data` (Tier 3) so the webhook's
    /// server-side `subscription_*` events land on the SAME PostHog person as the
    /// app's funnel.
    static var distinctId: String? {
        didStart ? PostHogSDK.shared.getDistinctId() : nil
    }

    // MARK: - Lifecycle

    static func start() {
        guard !didStart else { return }

        #if DEBUG
        Log.crashReporting.notice("Analytics & error tracking disabled in DEBUG builds — nothing sent to PostHog during development.")
        return
        #endif

        guard let key = readKey(), !key.isEmpty, !key.hasPrefix("phc_REPLACE") else {
            Log.crashReporting.notice("POSTHOG_API_KEY missing or placeholder in Info.plist — analytics & error tracking disabled this launch.")
            return
        }
        didStart = true

        let config = PostHogConfig(projectToken: key, host: readHost())

        // Auto-capture app install / open / update — gives us app_launched-
        // style lifecycle for free; our manual events ride alongside.
        config.captureApplicationLifecycleEvents = true
        // Native app: no UIKit screens to autocapture. We send manual events.
        config.captureScreenViews = false
        // Anonymous installs never spin up a person profile.
        config.personProfiles = .identifiedOnly
        // Error tracking: capture Mach exceptions, POSIX signals, and
        // uncaught NSExceptions as $exception events (fatal on next launch).
        config.errorTrackingConfig.autoCapture = true
        // Honor the toggle from the very first event.
        config.optOut = !isEnabled

        #if DEBUG
        config.debug = true
        #endif

        PostHogSDK.shared.setup(config)

        PostHogSDK.shared.register([
            "app_version": shortVersion(),
            "build_channel": channel(),
            "environment": environment(),
        ])
    }

    // MARK: - Product events

    /// Capture a product event. No-op until `start()` has run and while the
    /// user has analytics disabled. Property values must be metadata only —
    /// never user content (see the privacy contract above).
    static func capture(_ event: String, _ properties: [String: Any] = [:]) {
        guard didStart, isEnabled else { return }
        PostHogSDK.shared.capture(event, properties: properties)
    }

    /// Fire an event at most once per install, keyed by a UserDefaults flag.
    /// Used for first-time funnel markers like `onboarding_started`.
    static func captureOnce(_ event: String, key: String, _ properties: [String: Any] = [:]) {
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        capture(event, properties)
    }

    // MARK: - Toggle bridge

    /// Called when the Settings toggle flips so the SDK opt-out state tracks
    /// the preference live, without an app restart.
    static func setEnabled(_ enabled: Bool) {
        guard didStart else { return }
        enabled ? PostHogSDK.shared.optIn() : PostHogSDK.shared.optOut()
    }

    // MARK: - Entitlement super-properties (Tier 1)

    /// Registers the two billing super-properties (`entitlement_state` +
    /// `credits_remaining_bucket`) so EVERY event — existing and new — can be
    /// segmented by monetization state. Re-registering overwrites the prior
    /// values live, the same mechanism `start()` uses for the static
    /// super-properties; call this whenever the entitlement changes.
    ///
    /// No-op until `start()` has run (registering before setup would be lost).
    /// Privacy: only a coarse state enum and a credit BUCKET ever leave here —
    /// never the exact balance.
    static func updateEntitlementProperties(_ state: EntitlementState) {
        guard didStart else { return }
        PostHogSDK.shared.register([
            "entitlement_state": entitlementStateName(state),
            "credits_remaining_bucket": creditsRemainingBucket(state),
        ])
    }

    /// Coarse monetization state. `pre_trial` distinguishes a never-verified
    /// trial user (`.trial(creditsRemaining: nil)`) from one with a live balance.
    private static func entitlementStateName(_ state: EntitlementState) -> String {
        switch state {
        case .trial(let creditsRemaining):
            return creditsRemaining == nil ? "pre_trial" : "trial"
        case .expired:
            return "expired"
        case .byok:
            return "byok"
        case .managed:
            // Single managed tier (metered-credits Phase 6) — no starter/pro split.
            return "managed"
        }
    }

    /// Buckets the relevant credit balance so we can see "users near zero"
    /// without ever emitting a high-cardinality, near-PII exact count. `n/a`
    /// for the states with no meaningful balance (BYOK, expired, pre-trial).
    private static func creditsRemainingBucket(_ state: EntitlementState) -> String {
        let balance: Int
        switch state {
        case .trial(let creditsRemaining):
            guard let creditsRemaining else { return "n/a" } // pre-trial
            balance = creditsRemaining
        case .managed(let creditsRemaining, _):
            balance = creditsRemaining
        case .byok, .expired:
            return "n/a"
        }
        switch balance {
        case ..<1:    return "0"
        case 1...10:  return "1-10"
        case 11...50: return "11-50"
        default:      return "50+"
        }
    }

    // MARK: - Info.plist / environment

    /// Reads the production PostHog key. Only ever called in Release —
    /// `start()` returns early in DEBUG, so development transmits nothing.
    private static func readKey() -> String? {
        Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String
    }

    private static func readHost() -> String {
        let host = Bundle.main.object(forInfoDictionaryKey: "POSTHOG_HOST") as? String
        return (host?.isEmpty == false ? host! : "https://us.i.posthog.com")
    }

    private static func shortVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static func channel() -> String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    /// Coarse environment tag attached to every event. Belt-and-suspenders
    /// alongside the per-environment API key: even if a stray event landed
    /// in the wrong project, it's labeled so you can filter it out.
    private static func environment() -> String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }
}
