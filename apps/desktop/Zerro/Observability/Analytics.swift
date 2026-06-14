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

    // MARK: - Lifecycle

    static func start() {
        guard !didStart else { return }

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

    // MARK: - Info.plist / environment

    /// Picks the environment-appropriate PostHog key so development traffic
    /// stays out of the production project. Debug builds use the dev key;
    /// Release builds use the production key. This is what keeps prod-only
    /// Slack error alerts from firing on local/dev errors — dev events go
    /// to a different PostHog environment entirely.
    private static func readKey() -> String? {
        #if DEBUG
        return Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY_DEBUG") as? String
        #else
        return Bundle.main.object(forInfoDictionaryKey: "POSTHOG_API_KEY") as? String
        #endif
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
