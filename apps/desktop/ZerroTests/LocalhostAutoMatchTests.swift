//
//  LocalhostAutoMatchTests.swift
//  ZerroTests
//
//  Dev Mode (Phase 3) — port→folder zero-setup. Covers the PURE, testable
//  surface: localhost port extraction (the privacy boundary), the
//  URL→port→lookup→decision wiring (`resolveFolder`, with a stubbed URL + lookup
//  — the live Apple Event is exercised in the Part 7 E2E), the `devProjectByPort`
//  map persistence + reset, and the state fallback behaviors (hit pre-fills +
//  flags; a miss never clears the folder; a manual change drops the flag).
//

import XCTest
@testable import Zerro

@MainActor
final class LocalhostAutoMatchTests: XCTestCase {

    // MARK: - Port extraction (localhost-only)

    func testPortForLocalhostURL() {
        XCTAssertEqual(BrowserURLReader.portForLocalhostURL("http://localhost:3000/x"), 3000)
        XCTAssertEqual(BrowserURLReader.portForLocalhostURL("http://127.0.0.1:5173/"), 5173)
        XCTAssertEqual(BrowserURLReader.portForLocalhostURL("http://[::1]:8080"), 8080)
        XCTAssertEqual(BrowserURLReader.portForLocalhostURL("http://0.0.0.0:4321/path?q=1#f"), 4321)
        // Non-local hosts → nil (the privacy boundary — incl. LAN IPs, which are
        // NOT localhost).
        XCTAssertNil(BrowserURLReader.portForLocalhostURL("https://example.com"))
        XCTAssertNil(BrowserURLReader.portForLocalhostURL("https://example.com:3000"))
        XCTAssertNil(BrowserURLReader.portForLocalhostURL("http://192.168.1.5:3000"))
        XCTAssertNil(BrowserURLReader.portForLocalhostURL("http://localhost.evil.com:3000"))
        // Bare localhost (no explicit port) → nil — we require an explicit port.
        XCTAssertNil(BrowserURLReader.portForLocalhostURL("http://localhost/"))
        XCTAssertNil(BrowserURLReader.portForLocalhostURL("http://localhost"))
        // Garbage → nil.
        XCTAssertNil(BrowserURLReader.portForLocalhostURL("not a url"))
        XCTAssertNil(BrowserURLReader.portForLocalhostURL(""))
        XCTAssertNil(BrowserURLReader.portForLocalhostURL("about:blank"))
    }

    func testIsLocalhostExactHostMatch() {
        XCTAssertTrue(BrowserURLReader.isLocalhost("http://localhost:3000/"))
        XCTAssertTrue(BrowserURLReader.isLocalhost("http://127.0.0.1/"))
        XCTAssertTrue(BrowserURLReader.isLocalhost("http://[::1]:9/"))
        XCTAssertTrue(BrowserURLReader.isLocalhost("http://0.0.0.0:8080/"))
        XCTAssertFalse(BrowserURLReader.isLocalhost("https://example.com"))
        // A look-alike host must NOT pass (exact match, not substring).
        XCTAssertFalse(BrowserURLReader.isLocalhost("http://localhost.evil.com:3000"))
        XCTAssertFalse(BrowserURLReader.isLocalhost(""))
    }

    // MARK: - Fallback-chain wiring (reader stubbed)

    func testResolveFolderHitAutoFills() {
        let folder = URL(fileURLWithPath: "/proj/acme", isDirectory: true)
        let res = BrowserURLReader.resolveFolder(forURL: "http://localhost:3000/") { $0 == 3000 ? folder : nil }
        XCTAssertEqual(res, .autoFill(folder: folder, port: 3000))
    }

    func testResolveFolderMissNotesPort() {
        let res = BrowserURLReader.resolveFolder(forURL: "http://localhost:9999/") { _ in nil }
        XCTAssertEqual(res, .notePort(9999))
    }

    func testResolveFolderNonLocalOrNilIsNone() {
        let lookup: (Int) -> URL? = { _ in URL(fileURLWithPath: "/should/not/matter") }
        XCTAssertEqual(BrowserURLReader.resolveFolder(forURL: "https://example.com:3000", folderForPort: lookup), .none)
        XCTAssertEqual(BrowserURLReader.resolveFolder(forURL: nil, folderForPort: lookup), .none)
        XCTAssertEqual(BrowserURLReader.resolveFolder(forURL: "http://localhost", folderForPort: lookup), .none)
    }

    // MARK: - Port→folder map persistence

    func testPortMapPersistenceAndReset() {
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)
        let folder = URL(fileURLWithPath: "/proj/acme", isDirectory: true)
        prefs.setProjectURL(folder, forPort: 3000)
        XCTAssertEqual(prefs.projectURL(forPort: 3000)?.path, "/proj/acme")
        XCTAssertNil(prefs.projectURL(forPort: 5173))
        // Persisted: a fresh store over the same defaults reads it back.
        let reopened = PreferencesStore(defaults: defaults)
        XCTAssertEqual(reopened.projectURL(forPort: 3000)?.path, "/proj/acme")
        // In `resettable`, and reset wipes it.
        XCTAssertTrue(PreferencesStore.Keys.resettable.contains(PreferencesStore.Keys.devProjectByPort))
        reopened.resetToDefaults()
        XCTAssertNil(reopened.projectURL(forPort: 3000))
    }

    func testAutoDetectProjectToggleDefaultsOffPersistsAndResets() {
        let defaults = UserDefaults.ephemeralPreview()
        let prefs = PreferencesStore(defaults: defaults)
        // Default OFF is the whole point — nothing reads the browser until opt-in.
        XCTAssertFalse(prefs.devAutoDetectProject, "the Auto-Detect Project toggle defaults OFF")
        XCTAssertTrue(PreferencesStore.Keys.resettable.contains(PreferencesStore.Keys.devAutoDetectProject))

        prefs.devAutoDetectProject = true
        // Persists across stores over the same defaults.
        XCTAssertTrue(PreferencesStore(defaults: defaults).devAutoDetectProject, "the toggle persists")

        prefs.hasShownLocalhostDenialNote = true
        prefs.resetToDefaults()
        XCTAssertFalse(prefs.devAutoDetectProject, "reset restores default OFF")
        XCTAssertFalse(prefs.hasShownLocalhostDenialNote)
    }

    // MARK: - State fallback behaviors

    func testAutoMatchHitPrefillsAndFlags() {
        let state = AreaSelectorState()
        state.setDevState(isDevMode: true, agentID: "x", agentName: "X",
                          projectURL: URL(fileURLWithPath: "/last/used", isDirectory: true))
        state.setAutoMatchedProject(URL(fileURLWithPath: "/proj/acme", isDirectory: true), port: 3000)
        XCTAssertEqual(state.projectURL?.path, "/proj/acme")
        XCTAssertEqual(state.detectedLocalhostPort, 3000)
        XCTAssertTrue(state.projectAutoMatchedFromPort)
    }

    func testAutoMatchMissNeverClearsFolder() {
        let state = AreaSelectorState()
        state.setDevState(isDevMode: true, agentID: "x", agentName: "X",
                          projectURL: URL(fileURLWithPath: "/last/used", isDirectory: true))
        state.noteDetectedLocalhostPort(5173)
        XCTAssertEqual(state.projectURL?.path, "/last/used", "a miss must NOT clear the last-used folder")
        XCTAssertEqual(state.detectedLocalhostPort, 5173)
        XCTAssertFalse(state.projectAutoMatchedFromPort)
    }

    func testManualFolderChangeDropsAutoFlagButKeepsPort() {
        let state = AreaSelectorState()
        state.setAutoMatchedProject(URL(fileURLWithPath: "/proj/acme", isDirectory: true), port: 3000)
        XCTAssertTrue(state.projectAutoMatchedFromPort)
        state.setProjectURL(URL(fileURLWithPath: "/proj/other", isDirectory: true))   // manual "Change…"
        XCTAssertFalse(state.projectAutoMatchedFromPort, "a manual pick is no longer auto")
        XCTAssertEqual(state.detectedLocalhostPort, 3000, "the detected port is kept so the new pick is still learned")
    }

    func testLocalhostNoticeDismissesOnNextAction() {
        let state = AreaSelectorState()
        state.showLocalhostNotice(.denied)
        XCTAssertEqual(state.localhostNotice, .denied)
        state.closeDevSettingsMenu()
        XCTAssertNil(state.localhostNotice, "closing the menu dismisses the notice")
        state.showLocalhostNotice(.denied)
        state.setProjectURL(URL(fileURLWithPath: "/p", isDirectory: true))
        XCTAssertNil(state.localhostNotice, "picking a folder dismisses the notice")
    }

    // MARK: - Auto-Detect toggle state

    func testAutoDetectProjectEnabledStateSetter() {
        let state = AreaSelectorState()
        XCTAssertFalse(state.autoDetectProjectEnabled, "the toggle state defaults OFF")
        state.setAutoDetectProjectEnabled(true)
        XCTAssertTrue(state.autoDetectProjectEnabled)
        state.setAutoDetectProjectEnabled(false)
        XCTAssertFalse(state.autoDetectProjectEnabled)
    }

    func testAutoDetectInfoHoverClearsWhenMenuCloses() {
        let state = AreaSelectorState()
        state.setDevMode(true)
        state.toggleDevSettingsMenu()
        state.setAutoDetectInfoHovered(true)
        XCTAssertTrue(state.isAutoDetectInfoHovered)
        state.closeDevSettingsMenu()
        XCTAssertFalse(state.isAutoDetectInfoHovered, "closing the menu clears the info-icon hover")
    }
}
