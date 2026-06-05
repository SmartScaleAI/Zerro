//
//  PermissionsManager.swift
//  Zerro
//
//  Created by Colin Breeding on 5/27/26.
//
//  TCC permission detection for Screen Recording and Microphone.
//
//  Tri-state model (PermissionStatus) collapses Apple's two divergent
//  APIs into a single shape the UI can render uniformly:
//
//    • Screen Recording — CGPreflightScreenCaptureAccess() returns Bool
//      only, so we synthesize `.notDetermined` by tracking whether the
//      request has ever been issued (persisted in UserDefaults under
//      `hasRequestedScreenRecording`). Without this flag we'd be unable
//      to distinguish a fresh install from a user who's already said no.
//
//    • Microphone — AVCaptureDevice.authorizationStatus(for: .audio)
//      already returns a tri-state; .restricted collapses to .denied
//      because the user-facing outcome (MDM / Screen Time block) is
//      identical from our perspective.
//
//    • Accessibility — AXIsProcessTrusted() returns Bool only and there
//      is no "request" API; the user must toggle it manually in System
//      Settings. We surface this purely for UI reflection — Accessibility
//      is informational/optional, not gating. Status collapses to
//      .granted / .notDetermined; we never report .denied for AX
//      because there's no way to distinguish "off because never asked"
//      from "off because the user said no". DEFERRED: decide which
//      features (if any) actually require Accessibility — currently
//      none, since KeyboardShortcuts uses Carbon Hot Keys.
//
//  Polling: a 1s Timer drives `refreshStatuses()` so the onboarding view
//  can observe out-of-band changes (user toggles a switch in System
//  Settings while the onboarding window is open). Polling MUST be
//  stopped when no view needs it — long-lived timers in a menu-bar app
//  are an anti-pattern.
//
//  Mid-session revocation: the capture failure path consults
//  `isScreenRecordingGranted()` (and AVCaptureDevice.authorizationStatus
//  for the mic) to turn a generic capture stop into the dedicated
//  .screenRecordingRevoked / .microphoneRevoked failure copy — see
//  AppState.captureFailureReason.
//

import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import os
import ScreenCaptureKit
import Observation

// MARK: - PermissionStatus

enum PermissionStatus: Equatable {
    case notDetermined
    case granted
    case denied
}

// MARK: - PermissionsManager

@MainActor
@Observable
final class PermissionsManager {

    // MARK: Published state

    private(set) var screenRecordingStatus: PermissionStatus = .notDetermined
    private(set) var microphoneStatus: PermissionStatus = .notDetermined
    private(set) var accessibilityStatus: PermissionStatus = .notDetermined

    // MARK: Storage

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var monitoringTimer: Timer?

    /// Observer for `didBecomeActive` events that fire while a polling
    /// session is active. Used to auto-probe CGWindowList when the user
    /// returns focus to Zerro after a likely System Settings visit —
    /// covers the dev-drift case on ad-hoc-signed builds where
    /// CGPreflight false-negatives even after the user has enabled the
    /// permission toggle. Installed in `startPolling`, torn down in
    /// `stopPolling`. Skips the very first focus return (which is
    /// almost always the dismissal of the CGRequest popup itself —
    /// probing then would either redundantly run on a fresh grant or
    /// spawn a popup right on top of the user's deny answer).
    @ObservationIgnored private var pollingFocusObserver: NSObjectProtocol?
    @ObservationIgnored private var hasSeenFirstFocusReturnInPollingSession = false

    /// Set to `true` while a screen-recording TCC popup is in flight.
    /// Suppresses `.denied` reporting from `computeScreenRecordingStatus`
    /// so the onboarding step keeps rendering its "request" view while
    /// the popup is on screen — instead of snapping to "denied" the
    /// instant we set the persisted "has asked" flag.
    @ObservationIgnored private var isAwaitingScreenRecordingResponse = false
    /// Observer for `NSApplication.didBecomeActiveNotification`. Fires
    /// when the TCC popup dismisses (it had focus; on dismissal focus
    /// returns to us), at which point CGPreflight reflects the user's
    /// real answer and it's safe to commit the "has asked" flag.
    @ObservationIgnored private var screenRecordingResponseObserver: NSObjectProtocol?
    /// Most recent result of probing `SCShareableContent.current`. That
    /// API throws unless our process actually has Screen Recording
    /// permission, which makes it the most reliable signal — more
    /// reliable than `CGPreflightScreenCaptureAccess()` in particular,
    /// which false-negatives in dev builds when the codesign identity
    /// changes between rebuilds. Refreshed on every poll tick from
    /// `refreshScreenRecordingViaShareable`. Used as an override path
    /// inside `computeScreenRecordingStatus`.
    @ObservationIgnored private var screenRecordingGrantedViaShareable: Bool = false

    /// True while a `reactivateApp` boost/revert cycle is outstanding —
    /// from the moment we snapshot window levels until the pending revert
    /// runs. Guards against an overlapping `reactivateApp` (e.g. granting
    /// multiple permissions in quick succession) snapshotting windows that
    /// are already `.floating`, which would record the boosted level as the
    /// "original" and strand the window above everything on revert.
    @ObservationIgnored private var boostInProgress = false

    /// UserDefaults key used to distinguish "never asked" from "asked and
    /// denied" for Screen Recording, since CGPreflight returns Bool only.
    /// Sticky — once true, it never resets, which matches the OS behavior
    /// where the TCC prompt is one-shot per bundle ID.
    private enum Keys {
        static let hasRequestedScreenRecording = "vf.permissions.hasRequestedScreenRecording"
        static let hasRequestedMicrophone      = "vf.permissions.hasRequestedMicrophone"
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refreshStatuses()
    }

    // MARK: - Read

    /// Recomputes both statuses from the OS. Called on init, by the poll
    /// timer, and after each request. Cheap; both underlying APIs are
    /// synchronous and non-blocking.
    func refreshStatuses() {
        let prevScreen = screenRecordingStatus
        let prevMic = microphoneStatus
        let prevAX = accessibilityStatus

        screenRecordingStatus = computeScreenRecordingStatus()
        microphoneStatus = computeMicrophoneStatus()
        accessibilityStatus = computeAccessibilityStatus()

        // Reactivate the app when any permission transitions to .granted
        // out-of-band (i.e. the user toggled it on in System Settings
        // rather than via a TCC popup we triggered). Accessibility has
        // no `requestAccess` API, so this is the ONLY path that brings
        // the onboarding window back in front after the AX flip;
        // mic/screen-recording also benefit because some users skip
        // the popup and enable via the deep-link denied view. Guarded
        // by `hasPerformedInitialRefresh` so we don't yank focus on
        // app launch when the statuses go .notDetermined → .granted as
        // they're computed for the first time.
        if hasPerformedInitialRefresh {
            let nowGranted =
                (prevScreen != .granted && screenRecordingStatus == .granted) ||
                (prevMic != .granted && microphoneStatus == .granted) ||
                (prevAX != .granted && accessibilityStatus == .granted)
            if nowGranted {
                reactivateApp()
            }
        }
        hasPerformedInitialRefresh = true
    }

    /// Set after the first `refreshStatuses()` call so the transition
    /// detector above doesn't fire on the synthetic
    /// `.notDetermined → .granted` step that happens during init.
    private var hasPerformedInitialRefresh = false

    private func computeScreenRecordingStatus() -> PermissionStatus {
        // Cheap, popup-free signal first.
        if Self.isScreenRecordingGranted() {
            return .granted
        }
        // Cached result from an explicit fallback probe — set by
        // `refreshScreenRecordingViaShareable` (debug "Probe Shareable")
        // or `refreshScreenRecordingViaWindowList` ("Check Again" on the
        // denied step). We do NOT call either fallback automatically from
        // this method: on macOS 14+ both `SCShareableContent.current` AND
        // `CGWindowListCopyWindowInfo` (when reading `kCGWindowName`) can
        // spawn macOS's "Grant access in Privacy & Security" popup when
        // permission isn't granted. The previous implementation called
        // CGWindowList here on every refresh, which fired a duplicate
        // popup the instant `didBecomeActive` fired post-user-click. Both
        // fallbacks are now reserved for explicit user actions where one
        // popup is acceptable.
        if screenRecordingGrantedViaShareable {
            return .granted
        }
        // While a popup is in flight, treat the not-granted state as
        // `.notDetermined`. Without this, `hasRequestedScreenRecording`
        // gets committed at request time and the next refresh flips us
        // to `.denied` while the user is still looking at an unanswered
        // popup. We commit the flag only once we've observed a real
        // response (see `finalizeScreenRecordingResponse`).
        if isAwaitingScreenRecordingResponse {
            return .notDetermined
        }
        return defaults.bool(forKey: Keys.hasRequestedScreenRecording) ? .denied : .notDetermined
    }

    /// Strict "does the OS currently report Screen Recording as granted"
    /// check — `CGPreflightScreenCaptureAccess()` only. Used by
    /// `computeScreenRecordingStatus`, which drives the onboarding UI.
    ///
    /// We deliberately do NOT consult the CGWindowList second-opinion
    /// here. That fallback exists for the failure-reason path
    /// (`isScreenRecordingGrantedWithDevDriftFallback`, below) where a
    /// mid-recording failure of `SCStream` needs to be classified as
    /// either "permission revoked" or "something else" — at that
    /// moment, the binary really had permission a heartbeat ago, so
    /// the fallback acts as a reasonable second opinion against
    /// dev-time codesign drift.
    ///
    /// In the request flow, `requestScreenRecording` flips
    /// `hasRequestedScreenRecording` to `true` BEFORE the user has
    /// answered the popup, so any hasRequestedScreenRecording-gated
    /// fallback would still fire during the open-popup window and
    /// false-positive on system processes that leak `kCGWindowName`
    /// values (menu-bar items, Dock, ControlCenter). The pre-grant
    /// window must be authoritative: CGPreflight only.
    nonisolated static func isScreenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Failure-reason variant: CGPreflight, with the CGWindowList second
    /// opinion as a tiebreaker for dev codesign drift. ONLY safe to call
    /// from contexts where the binary just successfully started or ran
    /// a capture session and is now asking "do I still have permission?"
    /// — i.e., a recent observed grant exists. Calling from the
    /// pre-grant onboarding path would re-introduce the false positive
    /// the strict variant is designed to avoid.
    nonisolated static func isScreenRecordingGrantedWithDevDriftFallback() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return hasScreenRecordingPermissionViaWindowList()
    }

    private nonisolated static func hasScreenRecordingPermissionViaWindowList() -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        for entry in infoList {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32, ownerPID != myPID else {
                continue
            }
            if let name = entry[kCGWindowName as String] as? String, !name.isEmpty {
                return true
            }
        }
        return false
    }

    private func computeMicrophoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            // Dev-time TCC drift mitigation, mirrors the CGWindowList
            // fallback in computeScreenRecordingStatus. When the binary
            // is rebuilt (ad-hoc signing identity churns) or entitlements
            // change, TCC stops recognizing the previously-granted
            // identity and AVCaptureDevice flips back to .notDetermined
            // even though the user granted in a prior launch. Once we
            // have *ever* requested for this bundle, treat .notDetermined
            // as .granted — actual denial returns .denied (not
            // .notDetermined), so this can't mask a real "no" answer.
            // If TCC really has revoked, RecordingSession.start() will
            // fail and C5's failure path surfaces it via .failed(.mic*).
            if defaults.bool(forKey: Keys.hasRequestedMicrophone) {
                return .granted
            }
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    private func computeAccessibilityStatus() -> PermissionStatus {
        // No "request" API exists for AX; the user must toggle it
        // manually in System Settings. We map true -> .granted and
        // false -> .notDetermined because we can never confidently
        // distinguish "not asked" from "explicitly denied".
        AXIsProcessTrusted() ? .granted : .notDetermined
    }

    // MARK: - Request

    /// Triggers the system Screen Recording prompt on first call. On
    /// subsequent calls (after the user has answered once), the OS will
    /// not re-prompt — this is why the denied-state deep link into
    /// System Settings is essential.
    ///
    /// `CGRequestScreenCaptureAccess()` is NON-blocking on macOS — it
    /// queues the TCC popup and returns immediately, with no callback
    /// for the user's response. Two consequences:
    ///   1. We must NOT call `reactivateApp()` synchronously here.
    ///      Boosting our window to `.floating` while the popup is in
    ///      flight puts the onboarding chrome ON TOP of the popup, so
    ///      the user can't see/click it. The transition detector in
    ///      `refreshStatuses` is the right place — it fires
    ///      `reactivateApp` only after the status actually flips to
    ///      `.granted`, by which time the popup is gone.
    ///   2. We need polling to detect the grant, since `refreshStatuses`
    ///      called inline would still see `.notDetermined`. `startPolling`
    ///      runs at 1Hz and auto-stops once the SwiftUI step view's
    ///      `.task(id: effectiveStatus)` observes the transition and
    ///      calls `managePolling(.granted)`.
    func requestScreenRecording() {
        // Re-entry guard: if a request is already in flight, ignore.
        guard !isAwaitingScreenRecordingResponse else { return }

        // NOTE: we do NOT set `hasRequestedScreenRecording = true` here.
        // The flag gates the `.notDetermined` → `.denied` transition,
        // and setting it before the user has answered the popup would
        // make `refreshStatuses` report `.denied` while the popup is
        // still on screen. We commit the flag from
        // `finalizeScreenRecordingResponse` once we see real evidence
        // of a response.
        isAwaitingScreenRecordingResponse = true
        installScreenRecordingResponseObserver()
        _ = CGRequestScreenCaptureAccess()
        refreshStatuses()
        // Poll for the grant case (CGPreflight transitions to true the
        // moment the user clicks Allow, before the popup-dismiss
        // notification arrives). The deny case is caught by the
        // `didBecomeActive` observer below — CGPreflight stays false
        // either way after Deny, so we need the activation signal to
        // distinguish "popup still up" from "user denied".
        startPolling()

        // Safety net for the "CGRequest is a silent no-op" case. macOS
        // shows the request popup only on the FIRST call per bundle
        // (and on macOS Tahoe, `tccutil reset All` doesn't always
        // restore that one-shot eligibility). Subsequent calls return
        // immediately without spawning a popup, didBecomeActive never
        // fires, finalize never runs, and the Continue button on the
        // onboarding step becomes sticky — re-clicks are rejected by
        // the `isAwaitingScreenRecordingResponse` guard. After this
        // timeout, force-finalize so status flips to .denied and the
        // Open System Settings deep-link UI becomes available. If the
        // popup DID appear and the user clicks within the timeout, the
        // native finalize path runs first and the timeout's
        // isAwaiting guard short-circuits. If the user clicks after
        // the timeout, polling's CGPreflight check picks up the grant
        // within ~1s and the status flips to .granted directly.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isAwaitingScreenRecordingResponse else { return }
            Log.permissions.notice("CGRequest appears to have been a no-op — force-finalizing")
            self.finalizeScreenRecordingResponse()
        }
    }

    /// Subscribes to `NSApplication.didBecomeActiveNotification`. The TCC
    /// popup belongs to another process (tccd / ControlCenter), so it
    /// steals key focus from us when it opens and hands focus back when
    /// it dismisses. Receiving this notification while
    /// `isAwaitingScreenRecordingResponse` is true is our cue that the
    /// user has clicked Allow or Deny.
    private func installScreenRecordingResponseObserver() {
        guard screenRecordingResponseObserver == nil else { return }
        screenRecordingResponseObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Hop to MainActor because the closure stored in
            // NotificationCenter isn't isolated. PermissionsManager is
            // @MainActor.
            Task { @MainActor [weak self] in
                self?.finalizeScreenRecordingResponse()
            }
        }
    }

    /// Closes out the in-flight screen-recording request. Commits the
    /// persisted "has asked" flag (so a subsequent not-granted refresh
    /// reads as `.denied`, since the OS won't re-prompt), tears down
    /// the observer, and recomputes statuses so the onboarding step
    /// view rerenders into either the granted or denied sub-view.
    private func finalizeScreenRecordingResponse() {
        guard isAwaitingScreenRecordingResponse else { return }
        isAwaitingScreenRecordingResponse = false
        defaults.set(true, forKey: Keys.hasRequestedScreenRecording)
        if let observer = screenRecordingResponseObserver {
            NotificationCenter.default.removeObserver(observer)
            screenRecordingResponseObserver = nil
        }
        refreshStatuses()
    }

    /// Triggers the system Microphone prompt on first call. Same one-shot
    /// behavior as Screen Recording — denied state needs the deep link.
    /// Records `hasRequestedMicrophone` so the TCC-drift fallback in
    /// computeMicrophoneStatus can treat future `.notDetermined`
    /// readings as `.granted` (binary identity drift across rebuilds).
    ///
    /// Unlike `requestScreenRecording`, `AVCaptureDevice.requestAccess`
    /// is `async` and DOES wait for the user's response, so by the time
    /// `refreshStatuses` runs the new status is already settled. The
    /// transition detector inside `refreshStatuses` will then fire
    /// `reactivateApp` on its own.
    func requestMicrophone() async {
        defaults.set(true, forKey: Keys.hasRequestedMicrophone)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refreshStatuses()
    }

    /// After a system permission prompt dismisses (or the user toggles
    /// a permission directly in System Settings), focus drops back to
    /// whatever app was previously frontmost — and because Zerro is
    /// `LSUIElement` (no Dock icon), our onboarding window is NOT
    /// re-activated automatically. Without this hop the window slides
    /// behind whatever was in front, even though the granted-state view
    /// is rendering correctly underneath.
    ///
    /// Layered fix (different paths need different escape hatches):
    ///   1. Immediate `NSApp.activate(ignoringOtherApps: true)` — handles
    ///      the TCC-popup case where our continuation resumes right after
    ///      Allow and there's no actively-used app to fight with.
    ///   2. Deferred re-activation on the next tick — handles TCC's
    ///      focus-handoff race where the system finalizes the
    ///      next-frontmost transition AFTER our immediate activate.
    ///   3. Window-level boost to `.floating` on every titled window we
    ///      own — handles the "user toggled in System Settings and is
    ///      still actively using it" case (specifically the Accessibility
    ///      flow, which has no `requestAccess` API). LSUIElement apps
    ///      can be refused activation when another app holds active
    ///      focus, but `.floating` is enforced by the WindowServer
    ///      independent of app-activation state, so the window appears
    ///      above System Settings regardless.
    ///
    /// The boost is reverted when EITHER the user actually focuses our
    /// window (`didBecomeKeyNotification` fires) OR a long fallback
    /// timeout expires. The earlier implementation reverted after a
    /// fixed 550ms, which fired while the user was still in System
    /// Settings — they'd glance away to check the AX toggle, glance
    /// back to find our window had sunk behind Settings again. Keying
    /// the revert on user focus is what they intuitively expect: stay
    /// on top until I look at you, then behave normally.
    ///
    /// `.titled` filters the borderless pill / overlays out — those
    /// manage their own z-ordering.
    /// Public so other flows that lose focus to a system-owned popup
    /// (SecurityAgent for Keychain access, System Settings deep-links)
    /// can re-grab focus and bring our windows back to the front.
    /// Currently called by: the permission-grant transition detector
    /// (internal) and the Settings API-key field's Keychain read (external,
    /// for the SecurityAgent popup on ad-hoc-signed dev builds).
    func reactivateApp() {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            // If a prior boost/revert cycle is still outstanding, its windows
            // are already `.floating` and a revert is pending. Re-grabbing
            // focus above is enough; snapshotting now would capture `.floating`
            // as the "original" level and strand the window on revert. The
            // in-flight cycle's own `becomeKey`/timeout revert still fires.
            // The guard read and flag set must stay suspension-free (no `await`
            // between them) so two calls can't both pass the guard before either
            // sets the flag — inserting an await here silently reopens the race.
            guard !boostInProgress else { return }
            boostInProgress = true
            defer { boostInProgress = false }

            let titledWindows = NSApp.windows.filter {
                $0.isVisible && $0.styleMask.contains(.titled)
            }
            let originalLevels = titledWindows.map(\.level)

            // Boost level immediately so the window is visibly on top
            // even if AppKit's activate gets refused below.
            for window in titledWindows {
                window.level = .floating
                window.orderFrontRegardless()
            }

            // Second activate pass lands after TCC's focus settle.
            try? await Task.sleep(for: .milliseconds(50))
            NSApp.activate(ignoringOtherApps: true)
            for window in titledWindows {
                window.makeKeyAndOrderFront(nil)
            }

            // Hold the boost until the user actually focuses one of
            // our windows (becomeKey) — that's the signal that they've
            // returned to our app and the boost has served its purpose.
            // 30s fallback covers the case where the user goes
            // somewhere else entirely and never comes back to focus
            // our window.
            await Self.waitForBecomeKeyOrTimeout(
                windows: titledWindows,
                timeout: .seconds(30)
            )

            // Revert each window to whatever level it had before the
            // boost, only if no one has bumped it higher in the
            // meantime.
            for (window, originalLevel) in zip(titledWindows, originalLevels)
            where window.level == .floating {
                window.level = originalLevel
            }
        }
    }

    /// Awaits the earlier of (a) any of `windows` posting
    /// `NSWindow.didBecomeKeyNotification` or (b) `timeout` elapsing.
    /// Returns immediately if any window is already key. Used by
    /// `reactivateApp` to hold the `.floating` boost open until the
    /// user actually returns to our app.
    private static func waitForBecomeKeyOrTimeout(
        windows: [NSWindow],
        timeout: Duration
    ) async {
        if windows.contains(where: { $0.isKeyWindow }) { return }

        let windowSet: Set<ObjectIdentifier> = Set(windows.map(ObjectIdentifier.init))

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                let center = NotificationCenter.default
                let stream = center.notifications(
                    named: NSWindow.didBecomeKeyNotification
                )
                for await note in stream {
                    if let window = note.object as? NSWindow,
                       windowSet.contains(ObjectIdentifier(window)) {
                        return
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Polling

    /// Starts a 1s timer that refreshes both statuses. Idempotent —
    /// calling twice is a no-op. Used only while an onboarding step is
    /// showing a denied sub-state and needs to observe out-of-band
    /// changes from System Settings.
    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                // CGPreflight only. We deliberately do NOT call
                // `refreshScreenRecordingViaShareable` (popup-spawning)
                // or CGWindowList (also popup-spawning on macOS 14+)
                // from the timer. The focus-return observer below
                // handles dev-drift detection on a one-shot basis when
                // the user likely just came back from System Settings.
                self?.refreshStatuses()
            }
        }
        hasSeenFirstFocusReturnInPollingSession = false
        installPollingFocusObserver()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        uninstallPollingFocusObserver()
    }

    /// Auto-probes via CGWindowList when Zerro regains focus during a
    /// polling session, on the heuristic "user likely just toggled the
    /// permission in System Settings and returned". Handles the
    /// dev-drift case (ad-hoc-signed builds where CGPreflight stays
    /// false even after the user grants) by detecting the grant via a
    /// popup-free path when the timing is right.
    ///
    /// First focus return per polling session is skipped: it's almost
    /// always the dismissal of the CGRequest popup itself (the user
    /// just clicked Allow/Deny/Open Settings), and probing then would
    /// either redundantly run on a fresh grant CGPreflight already
    /// caught OR spawn a CGWindowList popup right on top of the deny
    /// answer the user just gave.
    ///
    /// Subsequent focus returns trigger one probe (with a 300ms delay
    /// so the OS state can propagate from a Settings toggle). The
    /// probe is silent when the grant exists; if it doesn't, one popup
    /// may appear — acceptable since the user just returned to Zerro
    /// during a denied-state polling session, where the implication is
    /// "I've been working on permissions".
    private func installPollingFocusObserver() {
        guard pollingFocusObserver == nil else { return }
        pollingFocusObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Skip the first focus return — it's the popup
                // dismissal, not a Settings-return.
                if !self.hasSeenFirstFocusReturnInPollingSession {
                    self.hasSeenFirstFocusReturnInPollingSession = true
                    return
                }
                // Don't probe while another CGRequest popup is in
                // flight (the safety-net case in requestScreenRecording
                // could leave isAwaiting=true briefly while a popup
                // shows late).
                if self.isAwaitingScreenRecordingResponse { return }
                // Let TCC's view of the world catch up to whatever the
                // user just did in Settings before probing.
                try? await Task.sleep(for: .milliseconds(300))
                if self.isAwaitingScreenRecordingResponse { return }
                self.refreshScreenRecordingViaWindowList()
            }
        }
    }

    private func uninstallPollingFocusObserver() {
        if let observer = pollingFocusObserver {
            NotificationCenter.default.removeObserver(observer)
            pollingFocusObserver = nil
        }
        hasSeenFirstFocusReturnInPollingSession = false
    }

    /// Probes `CGWindowListCopyWindowInfo` for non-self windows with a
    /// non-empty name. With Screen Recording granted, other apps' window
    /// names are visible; without it, names are stripped. So a single
    /// non-empty name = strong evidence we actually have the grant
    /// (covers dev-drift on ad-hoc-signed builds where CGPreflight
    /// false-negatives). On success, sets `screenRecordingGrantedViaShareable`
    /// and refreshes — the UI sees the .granted transition via the
    /// standard path.
    ///
    /// Side-effect warning: on macOS 14+, reading `kCGWindowName` from
    /// CGWindowList triggers macOS's "Open System Settings / Deny" popup
    /// when permission isn't granted. NEVER call from automatic refresh
    /// paths. Acceptable for user-initiated invocations (the "Check
    /// Again" button on the denied onboarding step) where one popup on
    /// user action is the right tradeoff: silent when granted, one
    /// prompt when not.
    func refreshScreenRecordingViaWindowList() {
        // CGPreflight first — if it returns true, no need to probe
        // CGWindowList and risk a popup.
        if Self.isScreenRecordingGranted() {
            refreshStatuses()
            return
        }
        let wasGranted = screenRecordingGrantedViaShareable
        screenRecordingGrantedViaShareable = Self.hasScreenRecordingPermissionViaWindowList()
        if !wasGranted && screenRecordingGrantedViaShareable {
            refreshStatuses()
        }
    }

    /// Probes `SCShareableContent.current` and updates
    /// `screenRecordingGrantedViaShareable`. The call throws iff our
    /// process can't see the windowable content list — i.e., iff Screen
    /// Recording is NOT granted. Success = real grant. When that flips
    /// from false to true we re-run `refreshStatuses` so the UI catches
    /// up via the standard transition path.
    ///
    /// Side-effect warning: when permission isn't granted, this call
    /// spawns a system "Open System Settings / Deny" popup. NEVER call
    /// from a polling loop. Reserved for explicit, user-initiated
    /// invocation (the debug "Probe Shareable" button) where one popup
    /// is acceptable to reliably break a stuck dev-drift state
    /// CGWindowList missed.
    func refreshScreenRecordingViaShareable() async {
        let wasGranted = screenRecordingGrantedViaShareable
        do {
            _ = try await SCShareableContent.current
            screenRecordingGrantedViaShareable = true
        } catch {
            screenRecordingGrantedViaShareable = false
        }
        if !wasGranted && screenRecordingGrantedViaShareable {
            // Real grant just observed. Trigger another refresh so the
            // transition detector runs and the SwiftUI step view sees
            // `.granted`. If a TCC popup is still on screen, the
            // transition detector's `reactivateApp` will bring our
            // window to the front so the user can see the onboarding
            // advance even though the popup hasn't been clicked away.
            refreshStatuses()
        }
    }

    /// Convenience used by onboarding step views: start polling iff the
    /// rendered sub-state is `.denied`, stop otherwise. Keeps the
    /// "only poll while on a denied screen" rule in one place.
    func managePolling(for status: PermissionStatus) {
        if status == .denied { startPolling() } else { stopPolling() }
    }

    // MARK: - Mid-session monitoring (Phase 10)

    /// Watches Screen Recording + Microphone TCC status for the duration
    /// of an active recording and fires `onRevoked` if either flips away
    /// from `.granted`. The callback runs on the MainActor, receives the
    /// dedicated `.screenRecordingRevoked` / `.microphoneRevoked` failure
    /// reason for AppState to set, and the monitor stops itself before
    /// firing (so the callback can teardown the recording without racing
    /// against a second tick).
    ///
    /// Polling at 1Hz mirrors `startPolling`'s cadence — TCC reads are
    /// synchronous and cheap, and a ≤1s observation lag from a real
    /// revocation to the pill flipping into the failure state is well
    /// under the perceptual threshold for "the app reacted to my change".
    /// Idempotent — calling while already monitoring is a no-op.
    ///
    /// Without this, a mid-session revocation is caught only when the
    /// next sample append fails inside the writer, which reads as a
    /// generic `.captureInterrupted` until `captureFailureReason()`
    /// re-classifies on the failure boundary. Proactive monitoring
    /// lands the user on the correct copy immediately.
    func startMonitoring(
        onRevoked: @escaping @MainActor (RecordingFailureReason) -> Void
    ) {
        guard monitoringTimer == nil else { return }
        // Snapshot at start. We only fire on a granted → not-granted
        // transition; the session is up so granted is the baseline by
        // construction. (If somehow it isn't, we'd false-positive on the
        // first tick — guarded by the snapshot to prevent that.)
        let baselineScreen = Self.isScreenRecordingGrantedWithDevDriftFallback()
        let baselineMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if baselineScreen && !Self.isScreenRecordingGrantedWithDevDriftFallback() {
                    self.stopMonitoring()
                    onRevoked(.screenRecordingRevoked)
                    return
                }
                if baselineMic && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    self.stopMonitoring()
                    onRevoked(.microphoneRevoked)
                    return
                }
            }
        }
    }

    /// Tears down the recording-monitor timer. Safe to call when not
    /// monitoring. AppState calls this from every recording exit path
    /// (handleSessionFinish for finished/cancelled/failed, plus the
    /// inline cancel paths) so the timer can't outlive the session.
    func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }

    /// Clears the persisted "has requested" tracking flags and recomputes
    /// statuses so the onboarding flow rebuilds from a clean slate. Used
    /// by the DEBUG "Reset Onboarding" menu action — without this, a
    /// stale `hasRequestedScreenRecording = true` causes the
    /// CGWindowList dev-drift fallback to consult system processes that
    /// leak window names, which can flip the screen-recording step to
    /// the allowed view before the user has actually granted anything.
    /// The TCC grant itself lives in the OS, not in UserDefaults — to
    /// clear that, use `resetTCCGrants()` (or the DEBUG "Reset
    /// Permissions" menu action that wraps it).
    func resetRequestFlags() {
        defaults.removeObject(forKey: Keys.hasRequestedScreenRecording)
        defaults.removeObject(forKey: Keys.hasRequestedMicrophone)
        refreshStatuses()
    }

    #if DEBUG
    /// Shells out to `tccutil reset All <bundleID>` to clear every TCC
    /// grant for this bundle (ScreenCapture + Microphone + Accessibility +
    /// any other service the OS has tracked), then clears our local
    /// tracking flags and refreshes statuses. Wraps the terminal command
    /// the dev-time workflow previously required so the onboarding flow
    /// can be re-tested from the menu-bar dropdown without dropping to a
    /// shell.
    ///
    /// `reset All` is preferred over `reset <service>` on macOS Tahoe
    /// (26.x): per-service resets occasionally leave the System Settings
    /// → Privacy & Security row stale (toggle still rendered ON), while
    /// the `All` variant reliably clears the bundle's entire entry in
    /// one pass.
    ///
    /// macOS caches TCC authorization per-process, so the *next* prompt
    /// only fires for a freshly-launched binary — calling this and then
    /// invoking `requestScreenRecording()` in the same process tends to
    /// see the cached grant rather than the cleared one. The menu action
    /// pairs this with `NSApp.terminate` so the user relaunches into a
    /// clean state.
    func resetTCCGrants() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            Log.permissions.error("resetTCCGrants: no bundle identifier")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "All", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
            // Bundle ID is .public (compile-time-derived from our own
            // Info.plist, not user content); exit status is .public.
            Log.permissions.notice(
                "tccutil reset All \(bundleID, privacy: .public) exited \(process.terminationStatus, privacy: .public)"
            )
        } catch {
            Log.permissions.error(
                "tccutil reset All failed: \(error.localizedDescription, privacy: .private)"
            )
        }
        resetRequestFlags()
    }
    #endif
}
