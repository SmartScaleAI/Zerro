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
        // SCShareableContent probe is the most reliable signal — covers
        // dev codesign drift where CGPreflight returns false despite
        // the user having actually granted in Settings.
        if Self.isScreenRecordingGranted() || screenRecordingGrantedViaShareable {
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
    private func reactivateApp() {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
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
                guard let self else { return }
                // Refresh the cheap synchronous checks first so the
                // common case (CGPreflight transitions to true) lands
                // immediately.
                self.refreshStatuses()
                // Then probe the more reliable async signal. If
                // CGPreflight is lagging behind the real grant — common
                // in dev builds with codesign drift — this is what
                // surfaces the transition.
                await self.refreshScreenRecordingViaShareable()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Probes `SCShareableContent.current` and updates
    /// `screenRecordingGrantedViaShareable`. The call throws iff our
    /// process can't see the windowable content list — i.e., iff Screen
    /// Recording is NOT granted. Success = real grant. When that flips
    /// from false to true we re-run `refreshStatuses` so the UI catches
    /// up via the standard transition path.
    private func refreshScreenRecordingViaShareable() async {
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

    /// Clears the persisted "has requested" tracking flags and recomputes
    /// statuses so the onboarding flow rebuilds from a clean slate. Used
    /// by the DEBUG "Reset Onboarding" menu action — without this, a
    /// stale `hasRequestedScreenRecording = true` causes the
    /// CGWindowList dev-drift fallback to consult system processes that
    /// leak window names, which can flip the screen-recording step to
    /// the allowed view before the user has actually granted anything.
    /// The TCC grant itself lives in the OS, not in UserDefaults — to
    /// clear that, run `tccutil reset ScreenCapture <bundle-id>`.
    func resetRequestFlags() {
        defaults.removeObject(forKey: Keys.hasRequestedScreenRecording)
        defaults.removeObject(forKey: Keys.hasRequestedMicrophone)
        refreshStatuses()
    }
}
