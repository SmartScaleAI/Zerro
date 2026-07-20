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
        // G-06: 0.0.0.0 is the wildcard BIND address, not a loopback host — a
        // URL claiming it isn't provably local, so it's outside the boundary.
        XCTAssertNil(BrowserURLReader.portForLocalhostURL("http://0.0.0.0:4321/path?q=1#f"))
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
        // G-06: the wildcard bind address is NOT loopback.
        XCTAssertFalse(BrowserURLReader.isLocalhost("http://0.0.0.0:8080/"))
        XCTAssertFalse(BrowserURLReader.isLocalhost("https://example.com"))
        XCTAssertFalse(BrowserURLReader.localhostHosts.contains("0.0.0.0"),
                       "0.0.0.0 must be out of the loopback set (G-06)")
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

    // MARK: - Live port→folder resolution precedence (live resolver stubbed)

    /// Helper: a state seeded into Dev Mode with a last-used folder, plus a
    /// fresh ephemeral-defaults preferences store.
    private func makeDevStateAndPrefs(lastUsed: String = "/last/used")
        -> (AreaSelectorState, PreferencesStore) {
        let state = AreaSelectorState()
        state.setDevState(isDevMode: true, agentID: "x", agentName: "X",
                          projectURL: URL(fileURLWithPath: lastUsed, isDirectory: true))
        let prefs = PreferencesStore(defaults: .ephemeralPreview())
        return (state, prefs)
    }

    func testLiveResolutionWinsOverStaleCacheAndRefreshesIt() {
        let (state, prefs) = makeDevStateAndPrefs()
        // Cache says port 3000 → the STALE folder; live says the genuine one.
        prefs.setProjectURL(URL(fileURLWithPath: "/proj/stale", isDirectory: true), forPort: 3000)
        let live = URL(fileURLWithPath: "/proj/live", isDirectory: true)

        let outcome = AreaSelectorWindowController.applyLocalhostAutoMatch(
            url: "http://localhost:3000/",
            liveFolderForPort: { $0 == 3000 ? live : nil },
            state: state, preferences: prefs, validateFolder: { _ in true })

        XCTAssertEqual(outcome, .autoFilled(folder: live))
        XCTAssertEqual(state.projectURL?.path, "/proj/live", "the live folder wins over the stale cache")
        XCTAssertTrue(state.projectAutoMatchedFromPort)
        XCTAssertEqual(state.detectedLocalhostPort, 3000)
        // The cache self-corrected to the live folder (bug fix #2).
        XCTAssertEqual(prefs.projectURL(forPort: 3000)?.path, "/proj/live", "the stale cache entry is refreshed to live")
    }

    func testLiveMissFallsBackToCache() {
        let (state, prefs) = makeDevStateAndPrefs()
        prefs.setProjectURL(URL(fileURLWithPath: "/proj/cached", isDirectory: true), forPort: 3000)

        let outcome = AreaSelectorWindowController.applyLocalhostAutoMatch(
            url: "http://localhost:3000/",
            liveFolderForPort: { _ in nil },   // live can't answer
            state: state, preferences: prefs, validateFolder: { _ in true })

        XCTAssertEqual(outcome, .autoFilled(folder: URL(fileURLWithPath: "/proj/cached", isDirectory: true)))
        XCTAssertEqual(state.projectURL?.path, "/proj/cached", "falls back to the cached folder (today's behavior)")
        // Cache unchanged (live agreed-by-absence → no needless write).
        XCTAssertEqual(prefs.projectURL(forPort: 3000)?.path, "/proj/cached")
    }

    func testTotalMissNeverClearsFolder() {
        let (state, prefs) = makeDevStateAndPrefs()
        // Live nil + cache nil for the detected port.
        let outcome = AreaSelectorWindowController.applyLocalhostAutoMatch(
            url: "http://localhost:5173/",
            liveFolderForPort: { _ in nil },
            state: state, preferences: prefs, validateFolder: { _ in true })

        XCTAssertEqual(outcome, .notedPort)
        XCTAssertEqual(state.projectURL?.path, "/last/used", "a total miss must NOT clear the last-used folder")
        XCTAssertEqual(state.detectedLocalhostPort, 5173, "the port is remembered so a later pick learns it")
        XCTAssertFalse(state.projectAutoMatchedFromPort)
        XCTAssertNil(prefs.projectURL(forPort: 5173))
    }

    func testNonLocalURLIsNoMatchAndLeavesFolder() {
        let (state, prefs) = makeDevStateAndPrefs()
        let outcome = AreaSelectorWindowController.applyLocalhostAutoMatch(
            url: "https://example.com:3000",
            liveFolderForPort: { _ in URL(fileURLWithPath: "/should/not/matter") },
            state: state, preferences: prefs, validateFolder: { _ in true })
        XCTAssertEqual(outcome, .noMatch)
        XCTAssertEqual(state.projectURL?.path, "/last/used")
        XCTAssertNil(state.detectedLocalhostPort)
    }

    func testAutoMatchPersistsLastUsed() {
        let (state, prefs) = makeDevStateAndPrefs()
        let live = URL(fileURLWithPath: "/proj/live", isDirectory: true)
        AreaSelectorWindowController.applyLocalhostAutoMatch(
            url: "http://localhost:3000/",
            liveFolderForPort: { _ in live },
            state: state, preferences: prefs, validateFolder: { _ in true })
        // Bug fix #1: an auto-matched folder is remembered as the global last-used.
        XCTAssertEqual(prefs.devProjectURL?.path, "/proj/live", "an auto-match updates the last-used folder")
    }

    // MARK: - G-06: candidate validation before adoption

    func testIsValidProjectFolderMatrix() {
        let folder = URL(fileURLWithPath: "/proj/acme", isDirectory: true)
        // A directory carrying `.git` → adoptable.
        XCTAssertTrue(LocalhostPortResolver.isValidProjectFolder(
            folder,
            directoryExists: { $0 == "/proj/acme" },
            fileExists: { $0 == "/proj/acme/.git" }))
        // Non-existent path (neither dir nor marker) → rejected.
        XCTAssertFalse(LocalhostPortResolver.isValidProjectFolder(
            folder,
            directoryExists: { _ in false },
            fileExists: { _ in false }))
        // A real directory WITHOUT `.git` (not a repo) → rejected.
        XCTAssertFalse(LocalhostPortResolver.isValidProjectFolder(
            folder,
            directoryExists: { $0 == "/proj/acme" },
            fileExists: { _ in false }))
        // A `.git` marker under a path that is no longer a DIRECTORY → rejected.
        XCTAssertFalse(LocalhostPortResolver.isValidProjectFolder(
            folder,
            directoryExists: { _ in false },
            fileExists: { $0 == "/proj/acme/.git" }))
        // A trailing slash is normalized before the marker probe.
        XCTAssertTrue(LocalhostPortResolver.isValidProjectFolder(
            URL(fileURLWithPath: "/proj/acme/", isDirectory: true),
            directoryExists: { $0 == "/proj/acme" },
            fileExists: { $0 == "/proj/acme/.git" }))
    }

    func testStaleCacheFolderIsRejectedNotAdopted() {
        let (state, prefs) = makeDevStateAndPrefs()
        // The learned map points at a folder that was deleted since it was
        // taught; live can't answer. The stale path must NOT be adopted — the
        // port is noted and the folder is left to manual selection.
        prefs.setProjectURL(URL(fileURLWithPath: "/proj/deleted", isDirectory: true), forPort: 3000)

        let outcome = AreaSelectorWindowController.applyLocalhostAutoMatch(
            url: "http://localhost:3000/",
            liveFolderForPort: { _ in nil },
            state: state, preferences: prefs, validateFolder: { _ in false })

        XCTAssertEqual(outcome, .notedPort, "a stale cache entry must not auto-fill")
        XCTAssertEqual(state.projectURL?.path, "/last/used", "the last-used folder is untouched")
        XCTAssertFalse(state.projectAutoMatchedFromPort)
        XCTAssertEqual(state.detectedLocalhostPort, 3000, "the port is still noted so a manual pick re-learns it")
    }

    func testInvalidLiveFolderFallsBackToValidCache() {
        let (state, prefs) = makeDevStateAndPrefs()
        // Live resolved a folder that vanished between resolution and adoption;
        // the cached folder is still real → the cache candidate wins.
        let cached = URL(fileURLWithPath: "/proj/cached", isDirectory: true)
        prefs.setProjectURL(cached, forPort: 3000)
        let gone = URL(fileURLWithPath: "/proj/gone", isDirectory: true)

        let outcome = AreaSelectorWindowController.applyLocalhostAutoMatch(
            url: "http://localhost:3000/",
            liveFolderForPort: { _ in gone },
            state: state, preferences: prefs, validateFolder: { $0 == cached })

        XCTAssertEqual(outcome, .autoFilled(folder: cached))
        XCTAssertEqual(state.projectURL?.path, "/proj/cached")
    }

    func testCacheHitDoesNotRewriteMap() {
        let (state, prefs) = makeDevStateAndPrefs()
        // Live AGREES with the cache → the guard must skip the redundant write.
        let folder = URL(fileURLWithPath: "/proj/same", isDirectory: true)
        prefs.setProjectURL(folder, forPort: 3000)
        AreaSelectorWindowController.applyLocalhostAutoMatch(
            url: "http://localhost:3000/",
            liveFolderForPort: { _ in folder },
            state: state, preferences: prefs, validateFolder: { _ in true })
        XCTAssertEqual(prefs.projectURL(forPort: 3000)?.path, "/proj/same")
        XCTAssertEqual(prefs.devProjectURL?.path, "/proj/same")
    }

    // MARK: - LocalhostPortResolver pure parsing (no sockets / no lsof)

    func testFirstPIDFromListenerOutput() {
        XCTAssertEqual(LocalhostPortResolver.firstPID(fromListenerOutput: "12345\n"), 12345)
        // Multiple listeners (IPv4 + IPv6 of one process) → take the first.
        XCTAssertEqual(LocalhostPortResolver.firstPID(fromListenerOutput: "12345\n12345\n"), 12345)
        XCTAssertEqual(LocalhostPortResolver.firstPID(fromListenerOutput: "  678  \n900\n"), 678)
        // No listener → empty output → nil.
        XCTAssertNil(LocalhostPortResolver.firstPID(fromListenerOutput: ""))
        XCTAssertNil(LocalhostPortResolver.firstPID(fromListenerOutput: "\n\n"))
        XCTAssertNil(LocalhostPortResolver.firstPID(fromListenerOutput: "garbage"))
        XCTAssertNil(LocalhostPortResolver.firstPID(fromListenerOutput: "0\n"), "pid 0 is not a real process")
    }

    func testCWDPathFromFieldOutput() {
        // `lsof -d cwd -Fn` shape: p<pid> / fcwd / n<path>.
        let out = "p12345\nfcwd\nn/Users/foo/project\n"
        XCTAssertEqual(LocalhostPortResolver.cwdPath(fromFieldOutput: out), "/Users/foo/project")
        // A path with spaces survives (the whole n-field is the path).
        XCTAssertEqual(
            LocalhostPortResolver.cwdPath(fromFieldOutput: "p1\nfcwd\nn/Users/foo/My Project\n"),
            "/Users/foo/My Project")
        // Non-absolute / missing n-field → nil.
        XCTAssertNil(LocalhostPortResolver.cwdPath(fromFieldOutput: "p1\nfcwd\n"))
        XCTAssertNil(LocalhostPortResolver.cwdPath(fromFieldOutput: ""))
    }

    func testProjectRootWalksUpToGitRoot() {
        let home = "/Users/foo"
        // .git lives at the repo root; the dev server runs in a sub-package.
        let exists: (String) -> Bool = { path in
            path == "/Users/foo/repo/.git" || path == "/Users/foo/repo/packages/web/package.json"
        }
        // From the sub-package, the nearest `.git` (repo root) wins over the
        // closer package.json — Dev Mode needs the git work-tree root.
        XCTAssertEqual(
            LocalhostPortResolver.projectRoot(forCWDPath: "/Users/foo/repo/packages/web",
                                              homePath: home, fileExists: exists)?.path,
            "/Users/foo/repo")
        // A trailing slash on the cwd is normalized away.
        XCTAssertEqual(
            LocalhostPortResolver.projectRoot(forCWDPath: "/Users/foo/repo/packages/web/",
                                              homePath: home, fileExists: exists)?.path,
            "/Users/foo/repo")
    }

    func testProjectRootFallsBackToManifestWhenNoGit() {
        let home = "/Users/foo"
        let exists: (String) -> Bool = { $0 == "/Users/foo/proj/package.json" }
        XCTAssertEqual(
            LocalhostPortResolver.projectRoot(forCWDPath: "/Users/foo/proj/src",
                                              homePath: home, fileExists: exists)?.path,
            "/Users/foo/proj", "nearest manifest dir when no .git anywhere up the chain")
    }

    func testProjectRootRejectsHomeAndRootAndMarkerless() {
        let home = "/Users/foo"
        // A server launched from a bare $HOME shell must NOT resolve $HOME — even
        // if $HOME happens to contain a marker.
        XCTAssertNil(LocalhostPortResolver.projectRoot(
            forCWDPath: "/Users/foo", homePath: home, fileExists: { _ in true }))
        // cwd at filesystem root → miss.
        XCTAssertNil(LocalhostPortResolver.projectRoot(
            forCWDPath: "/", homePath: home, fileExists: { _ in true }))
        // No marker found up to home → miss (never resolves home itself).
        XCTAssertNil(LocalhostPortResolver.projectRoot(
            forCWDPath: "/Users/foo/random/dir", homePath: home, fileExists: { _ in false }))
        // A relative / non-absolute cwd → miss.
        XCTAssertNil(LocalhostPortResolver.projectRoot(
            forCWDPath: "relative/path", homePath: home, fileExists: { _ in true }))
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
