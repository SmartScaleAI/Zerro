//
//  BrowserURLReader.swift
//  Zerro
//
//  Dev Mode (Phase 3) — reads the active browser tab's URL to auto-match a Dev
//  Mode project folder to the `localhost:<port>` the user is recording ("talk to
//  localhost:3000 and Zerro already knows the project").
//
//  PRIVACY BOUNDARY (not a nicety): this reader only ever returns a localhost /
//  loopback URL. A non-local URL is never returned upstream, never logged, never
//  transmitted — it's discarded the instant it's seen to be non-local. Callers
//  use the URL only to extract a port, then discard it; only `port → folder` is
//  ever persisted.
//
//  BEST-EFFORT + OFF-MAIN + BOUNDED: every failure mode — no browser running, an
//  unsupported browser, a window-less browser, TCC denied, an AppleScript error,
//  or a timeout — resolves to nil so detection can NEVER block or slow recording.
//  It's a bonus, never a requirement; the caller falls back to the last-used
//  folder.
//
//  Reads the browser app DIRECTLY via Apple Events — the browser does NOT need to
//  be frontmost (when the AreaSelector overlay is up, Zerro is frontmost). The
//  exact scripts were pinned against the live apps (Safari + Chrome, 2026-06-18):
//  the robust `application id "<bundleid>"` form, `current tab` (Safari) /
//  `active tab` (Chromium family) of `front window`.
//
//  STRATEGY (v1): probe the RUNNING supported browsers and return the localhost
//  URL only when EXACTLY ONE distinct localhost URL is found (unambiguous);
//  otherwise nil → fallback. Self-contained (no need to know which browser was
//  frontmost). A more precise future upgrade: target the browser that was
//  frontmost the instant the selector was invoked, or the window under the
//  selection region.
//
//  REQUIRES (Hardened Runtime, which this app uses for notarization): the
//  `com.apple.security.automation.apple-events` entitlement AND an
//  `NSAppleEventsUsageDescription` Info.plist string — without both, the Apple
//  Event is blocked even with a TCC grant. The first send per browser triggers
//  the one-time system Automation prompt.
//

import AppKit
import CoreServices
import Foundation

enum BrowserURLReader {

    /// A scriptable browser: its bundle id + the tab term its scripting
    /// dictionary uses for the active tab.
    private struct Browser {
        let bundleID: String
        /// "current tab" (Safari) or "active tab" (Chromium family).
        let tabTerm: String
    }

    /// Supported browsers, most common first. Firefox is intentionally ABSENT —
    /// it exposes no scriptable tab URL (documented gap → manual fallback).
    private static let browsers: [Browser] = [
        Browser(bundleID: "com.apple.Safari",            tabTerm: "current tab"),
        Browser(bundleID: "com.google.Chrome",           tabTerm: "active tab"),
        Browser(bundleID: "com.brave.Browser",           tabTerm: "active tab"),
        Browser(bundleID: "com.microsoft.edgemac",       tabTerm: "active tab"),
        Browser(bundleID: "com.vivaldi.Vivaldi",         tabTerm: "active tab"),
        Browser(bundleID: "company.thebrowser.Browser",  tabTerm: "active tab"),  // Arc
    ]

    /// The loopback hosts the privacy boundary admits (design §localhost-only).
    /// `0.0.0.0` is deliberately ABSENT (G-06): it's the unspecified/wildcard
    /// BIND address, not a loopback host — a URL claiming it isn't provably
    /// local, so admitting it would weaken the localhost-only boundary.
    static let localhostHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// Detect the active browser tab's localhost URL, or nil. Runs OFF-MAIN and is
    /// bounded by `timeout` (default short, so it never slows recording); never
    /// throws. Returns ONLY a localhost URL — never a non-local one.
    ///
    /// On the FIRST call per browser the system Automation prompt appears; while
    /// it's up the Apple Event blocks, so the first detection typically times out
    /// → nil → fallback, and subsequent detections (grant remembered) succeed.
    static func detectLocalhostURL(timeout: TimeInterval = 1.5) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let lock = NSLock()
            var resumed = false
            func finish(_ value: String?) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            // The blocking AppleScript probe runs on a background thread…
            DispatchQueue.global(qos: .userInitiated).async {
                finish(probeRunningBrowsersForLocalhost())
            }
            // …raced against a watchdog on a SEPARATE thread, so a blocked Apple
            // Event (e.g. the first-run TCC prompt) can't stall the caller. The
            // abandoned probe thread completes harmlessly later (its result is
            // dropped by the once-only `finish`).
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                finish(nil)
            }
        }
    }

    /// BLOCKING (call off-main): query each RUNNING supported browser's front-tab
    /// URL, keep only localhost ones, and return the single distinct localhost URL
    /// if unambiguous (else nil).
    private static func probeRunningBrowsersForLocalhost() -> String? {
        var localhostURLs: [String] = []
        for browser in browsers where isRunning(browser.bundleID) {
            guard let url = frontTabURL(browser), isLocalhost(url) else { continue }
            localhostURLs.append(url)
        }
        let distinct = Set(localhostURLs)
        // Exactly one running browser shows a localhost URL → unambiguous.
        return distinct.count == 1 ? distinct.first : nil
    }

    /// Whether a browser is already running — checked FIRST so we never script a
    /// non-running browser (an AppleScript `tell` would LAUNCH it, which detection
    /// must never do).
    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Run one browser's front-tab AppleScript. Returns nil on ANY error (no
    /// window, TCC denied, unscriptable, etc.) — never throws into the caller.
    private static func frontTabURL(_ browser: Browser) -> String? {
        let source = "tell application id \"\(browser.bundleID)\" to get URL of \(browser.tabTerm) of front window"
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else { return nil }
        return descriptor.stringValue
    }

    /// True iff `urlString`'s host is a loopback host. THE privacy gate: a URL that
    /// isn't localhost is never returned upstream. Pure — also reused by the port
    /// extractor (Part 2).
    static func isLocalhost(_ urlString: String) -> Bool {
        guard let host = URLComponents(string: urlString)?.host?.lowercased() else { return false }
        // URLComponents already strips the brackets from `[::1]`, but normalize
        // defensively in case a raw bracketed host slips through.
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return localhostHosts.contains(normalized)
    }

    // MARK: - Port extraction (Part 2)

    /// The port from a localhost URL, or nil. Returns the port ONLY when the host
    /// is a loopback host (the privacy boundary) AND an EXPLICIT port is present —
    /// a bare `http://localhost` (implicit :80 / :443) isn't a dev-server scenario
    /// worth mapping, so we require an explicit port. Any non-local host → nil.
    /// Pure (no I/O); unit-tested.
    static func portForLocalhostURL(_ urlString: String) -> Int? {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased() else { return nil }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard localhostHosts.contains(normalized) else { return nil }
        return components.port   // explicit port only; bare host (no port) → nil
    }

    /// What the Dev-Mode folder should do given a (possibly nil) detected URL and
    /// a `port → folder` lookup. Pure — captures the URL→port→lookup→decision
    /// wiring so it's testable with a stubbed URL + lookup (the live Apple Event
    /// isn't). The caller turns each case into a state mutation.
    enum LocalhostFolderResolution: Equatable {
        /// HIT — the port is mapped: pre-fill `folder` and show the hint.
        case autoFill(folder: URL, port: Int)
        /// MISS — a localhost port with no mapping yet: remember it so a folder
        /// pick / record learns the mapping (don't touch the current folder).
        case notePort(Int)
        /// No localhost port (non-local URL, no URL, denied, timed out) → fall
        /// back to the last-used folder; never clear a set folder.
        case none
    }

    /// Resolve the folder action for `urlString` using `folderForPort`. nil URL or
    /// a non-localhost URL → `.none`; a localhost port → `.autoFill` if mapped
    /// else `.notePort`.
    static func resolveFolder(forURL urlString: String?, folderForPort: (Int) -> URL?) -> LocalhostFolderResolution {
        guard let urlString, let port = portForLocalhostURL(urlString) else { return .none }
        if let folder = folderForPort(port) { return .autoFill(folder: folder, port: port) }
        return .notePort(port)
    }

    // MARK: - Automation permission status (no prompt)

    /// Current TCC Automation status for a target, queried WITHOUT prompting
    /// (`AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`).
    /// Lets the UI show the one-time primer ONLY when a detection would actually
    /// surface the system prompt, and the denial explainer only on a real denial.
    enum AutomationStatus { case granted, denied, notDetermined }

    static func automationStatus(forBundleID bundleID: String) -> AutomationStatus {
        guard let data = bundleID.data(using: .utf8) else { return .notDetermined }
        var target = AEAddressDesc()
        let createErr = data.withUnsafeBytes { raw in
            AECreateDesc(typeApplicationBundleID, raw.baseAddress, data.count, &target)
        }
        guard OSStatus(createErr) == noErr else { return .notDetermined }
        defer { AEDisposeDesc(&target) }
        // typeWildCard/typeWildCard → overall automation permission to the target.
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        switch status {
        case noErr:                            return .granted
        case OSStatus(errAEEventNotPermitted): return .denied   // -1743
        default:                               return .notDetermined  // -1744 needs-consent, procNotFound, …
        }
    }

    /// True iff a real detection would surface the system Automation prompt — i.e.
    /// some RUNNING supported browser's permission is not yet determined. The
    /// gate for the one-time primer (don't promise a prompt that won't appear).
    static func automationWouldPrompt() -> Bool {
        browsers.contains { isRunning($0.bundleID) && automationStatus(forBundleID: $0.bundleID) == .notDetermined }
    }

    /// True iff a RUNNING supported browser's automation was explicitly denied —
    /// the gate for the one-time, dismissible denial explainer.
    static func automationDenied() -> Bool {
        browsers.contains { isRunning($0.bundleID) && automationStatus(forBundleID: $0.bundleID) == .denied }
    }
}
