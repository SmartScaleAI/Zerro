//
//  OnboardingState.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  Live state for the onboarding window. Owned by the App as @State and
//  injected into the onboarding scene's environment. Matches the
//  @MainActor @Observable pattern AppState and PreferencesStore use.
//
//  Persists two pieces of state to UserDefaults:
//    • hasCompletedOnboarding — sticky flag set on All Set, gates
//      first-launch window auto-present and hotkey inertness.
//    • currentStep — survives the SIGKILL macOS issues when an app
//      gains Screen Recording permission. Without persisting this,
//      the user would land back on Welcome after every Screen
//      Recording grant and could never progress past step 2. The
//      step is cleared on completeOnboarding so a future re-trigger
//      of onboarding starts clean.
//
//  This DOES extend "resume where you left off" beyond the original
//  spec's no-resume guidance — but only because the OS-mandated kill
//  is a different beast from a user intentionally quitting. A normal
//  Cmd-Q mid-onboarding will also resume, which is a small UX cost
//  worth paying to make the OS-kill path survivable.
//
//  UserDefaults-backed manually (rather than via @AppStorage) because
//  @AppStorage is a SwiftUI property wrapper that only works in Views,
//  not in an @Observable class.
//

import Foundation
import Observation
import os

/// Namespace for onboarding window-scene constants. Lives alongside the
/// state so callers that need to programmatically open or dismiss the
/// window (e.g. the All Set step's Done action) can do so without
/// hard-coding string identifiers.
enum OnboardingScene {
    static let windowID = "onboarding"
}

@MainActor
@Observable
final class OnboardingState {

    // MARK: - Consent constants (Phase 22)
    //
    // Single sources of truth for the consent gate. `currentTermsVersion`
    // is the "Last updated" date stamped on the live Terms of Service /
    // Privacy Policy — bump it whenever those documents change materially
    // and every user is re-papered on next launch (see `needsConsent`).
    // `analyticsDefaultOptIn` controls only the DEFAULT position of the
    // onboarding analytics toggle (true = on-by-default / opt-out posture);
    // route the default through this constant so it can be flipped to
    // opt-in later without touching the view. (EU/US geo-detection of the
    // default is DEFERRED — see ConsentStepView.)

    static let currentTermsVersion = "2026-06-15"
    static let analyticsDefaultOptIn = true

    // MARK: - Persisted

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    /// True when THIS launch surfaced onboarding solely to re-collect
    /// consent — the user already finished onboarding but the Terms version
    /// they accepted is stale. In this mode the consent step dismisses the
    /// window on accept instead of advancing into the (already-completed)
    /// rest of the flow. Runtime-only; computed once in `init`.
    private(set) var isReconsenting: Bool = false

    /// Survives the OS-issued SIGKILL on Screen Recording grant.
    /// Persisted on every change; cleared on completeOnboarding.
    var currentStep: OnboardingStep {
        didSet { defaults.set(currentStep.rawValue, forKey: Keys.currentStep) }
    }

    // MARK: - Dev sub-state pins
    //
    // DEBUG-only overrides set by the dev panel. When non-nil, the
    // permission step uses the pinned value instead of the live
    // PermissionsManager value, so we can render any sub-state for
    // visual review without actually toggling system permissions.
    // Production code reads these as nil — only OnboardingDevPanel
    // writes them.

    var pinnedScreenSubState: PermissionStatus?
    var pinnedMicSubState: PermissionStatus?

    // MARK: - Storage

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let hasCompletedOnboarding = "vf.onboarding.hasCompletedOnboarding"
        static let currentStep            = "vf.onboarding.currentStep"
        // Phase 22 — clickwrap consent record.
        static let termsAcceptedVersion   = "vf.consent.termsAcceptedVersion"
        static let termsAcceptedAt        = "vf.consent.termsAcceptedAt"
        static let privacyAcceptedVersion = "vf.consent.privacyAcceptedVersion"
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        // `integer(forKey:)` returns 0 for missing keys, which maps to
        // .welcome — exactly the right default for first-ever launches.
        let rawStep = defaults.integer(forKey: Keys.currentStep)
        self.currentStep = OnboardingStep(rawValue: rawStep) ?? .welcome

        // Phase 22: re-consent gate. If the user already finished onboarding
        // but the Terms version they accepted is stale (or absent), surface
        // the consent screen once before app use. Pin the window to the
        // consent step; the consent view dismisses on accept in this mode.
        let needsConsentNow = defaults.string(forKey: Keys.termsAcceptedVersion) != Self.currentTermsVersion
        if hasCompletedOnboarding && needsConsentNow {
            self.isReconsenting = true
            self.currentStep = .consent
        }
    }

    // MARK: - Navigation

    func advance() {
        // First forward step out of Welcome is our "onboarding started"
        // funnel marker — fired at most once per install.
        if currentStep == .welcome {
            Analytics.captureOnce("onboarding_started", key: "vf.analytics.onboardingStarted")
        }
        if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
            currentStep = next
        }
    }

    // Back-navigation is intentionally omitted (H-10): the flow is short and
    // gate-driven — consent and email verification are one-way gates (the
    // email step's verified state is view-local, so returning would force a
    // re-verification), and the only gate-free hops (devMode → permissions,
    // allSet → devMode) aren't worth the affordance. DEBUG builds navigate
    // freely via the dev panel's `jump(to:)` buttons.

    func jump(to step: OnboardingStep) {
        currentStep = step
    }

    // MARK: - Step-view funnel (Tier 4)

    /// Fire `onboarding_step_viewed` at most once per step per install. Deduped
    /// via `captureOnce` (a UserDefaults flag keyed by the step's stable
    /// analytics name) so the SIGKILL relaunch on the Screen Recording grant,
    /// a Cmd-Q resume, and back-navigation don't inflate the funnel. Fired from
    /// the view layer (not `advance()`) so the step restored after the relaunch
    /// is still counted.
    func recordStepViewed(_ step: OnboardingStep) {
        Analytics.captureOnce(
            "onboarding_step_viewed",
            key: "vf.analytics.onboardingStep.\(step.analyticsName)",
            [
                "step": step.analyticsName,
                "step_index": step.rawValue,
                "total_steps": OnboardingStep.allCases.count,
            ]
        )
    }

    // MARK: - Consent (Phase 22)

    /// True when the locally-recorded Terms version doesn't match the current
    /// one (never accepted, or accepted an older version). Drives both the
    /// first-run consent gate and the re-consent-on-launch check.
    var needsConsent: Bool {
        defaults.string(forKey: Keys.termsAcceptedVersion) != Self.currentTermsVersion
    }

    /// Static consent read for the LAUNCH BOOTSTRAP (I-03): the inverse of
    /// `needsConsent`, callable before any OnboardingState instance exists.
    /// Same Keys/currentTermsVersion source of truth. Telemetry startup
    /// (CrashReporting.start → Analytics.start) is gated on this in ZerroApp's
    /// one-shot block, so nothing transmits before the user has accepted the
    /// consent step.
    static func hasCurrentConsent(defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: Keys.termsAcceptedVersion) == currentTermsVersion
    }

    /// Whether the onboarding window should auto-present at launch: either
    /// onboarding isn't finished, or finished users owe fresh consent. Read
    /// by `ZerroApp` to drive the window's launch behavior.
    var shouldPresentOnboardingOnLaunch: Bool {
        !hasCompletedOnboarding || needsConsent
    }

    /// Enter re-consent mode: pin the window to the consent step and mark the
    /// session as reconsenting, so the consent accept DISMISSES (see
    /// `OnboardingConsentStep.agree`) instead of advancing a completed user
    /// into the rest of the flow. `init` only catches the stale-terms case at
    /// launch; the record-attempt gate calls this (H-06) because a prior
    /// permission jump may have moved `currentStep` off `.consent`, and
    /// `isReconsenting` is private(set).
    func beginReconsent() {
        isReconsenting = true
        currentStep = .consent
    }

    // MARK: - Record-attempt gate (H-06)

    /// What a record attempt owes before capture can start, in priority
    /// order. Pure and static so unit tests pin the ORDER itself: an
    /// outstanding re-consent must be satisfied BEFORE the permission gate
    /// can engage. If permissions won while consent was owed, the permission
    /// flow's tail ran `completeOnboarding()` but never `recordConsent()`,
    /// so `needsConsent` stayed true and every record attempt re-hijacked
    /// the window — a re-onboarding loop (H-06).
    enum RecordGateAction: Equatable {
        /// First run — onboarding never finished; open the window as-is.
        case openOnboarding
        /// Completed user owes fresh consent — pin consent in reconsent mode.
        case reconsent
        /// Completed and consented, but a gating permission was revoked.
        case requestPermissions
        /// Nothing owed — fall through to the entitlement gate.
        case proceed
    }

    nonisolated static func recordGateAction(
        hasCompletedOnboarding: Bool,
        needsConsent: Bool,
        screenGranted: Bool,
        micGranted: Bool
    ) -> RecordGateAction {
        if !hasCompletedOnboarding { return .openOnboarding }
        if needsConsent { return .reconsent }
        if !screenGranted || !micGranted { return .requestPermissions }
        return .proceed
    }

    /// Persist the clickwrap consent record. The affirmative button press is
    /// the consent action; this is the only writer of these keys.
    func recordConsent() {
        let now = ISO8601DateFormatter().string(from: Date())
        defaults.set(Self.currentTermsVersion, forKey: Keys.termsAcceptedVersion)
        defaults.set(now, forKey: Keys.termsAcceptedAt)
        defaults.set(Self.currentTermsVersion, forKey: Keys.privacyAcceptedVersion)
        isReconsenting = false
        Log.billing.notice("terms consent recorded locally — version \(Self.currentTermsVersion, privacy: .public)")

        // I-03: telemetry startup was DEFERRED at bootstrap when this launch
        // lacked current consent (first run, or a finished user owing
        // re-consent). Fire the one-shot hook now, AFTER the consent record is
        // written — this single call site covers BOTH accept paths. The
        // analytics toggle has already persisted the user's opt-in/out choice
        // (CrashReporting.isEnabledDefaultsKey via @AppStorage), so
        // Analytics.start() reads the correct optOut on its first event.
        // Nil-out before invoking → strictly one-shot (Analytics.start is
        // additionally didStart-guarded).
        if let startTelemetry = AppDelegate.startTelemetryOnConsent {
            AppDelegate.startTelemetryOnConsent = nil
            startTelemetry()
        }

        // DEFERRED Phase 22.1 — server-side acceptance record.
        // Consent is collected BEFORE the email-verification step, so there is
        // no authenticated session here to tie an acceptance to. To record
        // server-side we need, end to end:
        //   1. A Supabase migration adding a `terms_acceptances` table
        //      (account/email key, terms_version, accepted_at, app_version).
        //   2. A `/terms-accept` edge function (verify_jwt=false, Bearer the
        //      trial/session token, matching the existing ManagedBackend
        //      pattern — the app holds no anon key) that inserts a row.
        //   3. A post-sign-in sync: after EmailStepView verification succeeds
        //      (where the trial token first exists), POST the locally-stored
        //      acceptance (version + termsAcceptedAt + app version) so the
        //      account carries it. Re-runnable / idempotent on (account,
        //      version) so a re-verify doesn't duplicate rows.
        // Until that migration + function ship, the local record above is the
        // authority and is synced opportunistically once 22.1 lands.
    }

    // MARK: - Lifecycle

    func completeOnboarding() {
        Analytics.capture("onboarding_completed")
        hasCompletedOnboarding = true
        // Clear the persisted step so a future re-trigger of the
        // onboarding window (permission revocation path) starts at
        // Welcome rather than All Set.
        currentStep = .welcome
    }
}
