//
//  PermissionsManager.swift
//  VisualFlowAI
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
//  DEFERRED Phase 7: ScreenCaptureKit integration once permission is granted.
//  DEFERRED: handling of permission revocation while a recording is in flight.
//

import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
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

    /// UserDefaults key used to distinguish "never asked" from "asked and
    /// denied" for Screen Recording, since CGPreflight returns Bool only.
    /// Sticky — once true, it never resets, which matches the OS behavior
    /// where the TCC prompt is one-shot per bundle ID.
    private enum Keys {
        static let hasRequestedScreenRecording = "vf.permissions.hasRequestedScreenRecording"
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
        screenRecordingStatus = computeScreenRecordingStatus()
        microphoneStatus = computeMicrophoneStatus()
        accessibilityStatus = computeAccessibilityStatus()
    }

    private func computeScreenRecordingStatus() -> PermissionStatus {
        // Primary check. Reliable for installed/release builds.
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }
        // Fallback: during development the binary's codesign identity
        // changes on every rebuild, and TCC can lag (or never refresh)
        // its association — so CGPreflightScreenCaptureAccess() returns
        // false even though the user has granted the permission. The
        // CGWindowList behavior is the canonical second-opinion check:
        // with screen recording granted, foreign-process window dicts
        // carry real `kCGWindowName` values; without it they're blank
        // or nil. We look at windows owned by OTHER processes (own-pid
        // names are visible without permission), and treat any
        // non-empty name as proof of permission.
        if hasScreenRecordingPermissionViaWindowList() {
            return .granted
        }
        return defaults.bool(forKey: Keys.hasRequestedScreenRecording) ? .denied : .notDetermined
    }

    private func hasScreenRecordingPermissionViaWindowList() -> Bool {
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
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
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
    func requestScreenRecording() {
        defaults.set(true, forKey: Keys.hasRequestedScreenRecording)
        _ = CGRequestScreenCaptureAccess()
        refreshStatuses()
    }

    /// Triggers the system Microphone prompt on first call. Same one-shot
    /// behavior as Screen Recording — denied state needs the deep link.
    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refreshStatuses()
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
                self?.refreshStatuses()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Convenience used by onboarding step views: start polling iff the
    /// rendered sub-state is `.denied`, stop otherwise. Keeps the
    /// "only poll while on a denied screen" rule in one place.
    func managePolling(for status: PermissionStatus) {
        if status == .denied { startPolling() } else { stopPolling() }
    }
}
