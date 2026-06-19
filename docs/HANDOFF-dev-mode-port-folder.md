# Claude Code handoff — port→folder zero-setup (Phase 3 "magic")

Make Dev Mode **infer the project folder from the localhost port the user is
recording**. Read the browser's current `localhost:<port>` URL, keep a persisted
`port → folder` map, and the next time you record that port the folder is
pre-filled with no click. "Talk to localhost:3000 and Zerro already knows the
project."

This is greenfield OS integration (Apple Events + a TCC permission) with privacy
implications, so **Part 1 is a verify-and-report STOP** — get the browser-URL
reader + the entitlement working and confirm it reads a real localhost URL, BEFORE
wiring the UX. Then build Parts 2–6, then **STOP for the live E2E** (Part 7).

## Ground rules (read these first — they're the spec's spine)
- **Opt-in + Dev-Mode-only.** The browser URL is read ONLY in Dev Mode, only to
  match a folder. A settings toggle disables the whole magic. Default: on, but it
  degrades silently when off/denied.
- **localhost-only.** Act ONLY on `localhost` / `127.0.0.1` / `[::1]` / `0.0.0.0`
  URLs. Any non-local URL is ignored and never read-into-state, never logged, never
  transmitted. This is a privacy boundary, not a nicety.
- **Never block or slow recording.** Detection is best-effort and runs off-main
  with a short timeout. Permission denied, no browser, unsupported browser, AppleScript
  error, timeout → instant fallback to the existing last-used folder
  (`devProjectPath`). The magic is a bonus, never a requirement.
- **No regression.** With the toggle off or permission denied, Dev Mode behaves
  EXACTLY as today (last-used folder + manual pick).

## What exists today
- `Preferences/PreferencesStore.swift`: the folder is a single plain path —
  `Keys.devProjectPath` (`vf.dev.projectPath`), non-sandboxed so no bookmark. This
  is the global "last-used" fallback. Add the port map alongside it.
- `Surfaces/AreaSelector/AreaSelectorWindowController.swift`:
  `handleDevModeEntered()` (~764, the dev-settings entry), `presentFolderPicker` /
  `state.setProjectURL(url)` (~940/969). This is where a detected folder gets
  pre-filled.
- `Zerro.entitlements`: currently ONLY `com.apple.security.device.audio-input`.
  No automation entitlement yet.
- **No existing AppleScript** anywhere — you're building the reader from scratch.

## Part 1 — the browser-URL reader + permission (STOP, report back)
Build `Services/Dev/BrowserURLReader.swift` and the entitlement/Info.plist
plumbing, then VERIFY it reads a real localhost URL from the user's browser.

**Permission plumbing (both required for a notarized/Hardened-Runtime app):**
- `Zerro.entitlements`: add `com.apple.security.automation.apple-events` = `true`.
  Under Hardened Runtime, Apple Events are BLOCKED without this even if TCC is
  granted. (Confirm Hardened Runtime is on — it is, for notarization.)
- `Info.plist`: add `NSAppleEventsUsageDescription` — the per-target TCC prompt
  string, e.g. "Zerro reads your browser's current localhost address to
  auto-match your Dev Mode project folder." Without it the prompt/grant fails.

**The reader:**
- Per-browser AppleScript that asks the browser app **directly** (it does NOT need
  to be the frontmost app — `tell application "Safari" to get URL of current tab
  of front window`; Chromium family — Chrome/Brave/Edge/Vivaldi — use `active tab
  of front window`; Arc similar). Run off-main, short timeout, `NSAppleScript` or a
  scoped `osascript`. **Firefox has no scriptable URL — treat as unsupported →
  nil** (documented gap; falls back to manual).
- **The overlay-frontmost wrinkle (important):** when the AreaSelector overlay is
  up, *Zerro* is frontmost, not the browser — so you can't use
  `NSWorkspace.frontmostApplication` at detection time. Two acceptable strategies:
  1. Capture `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` at the
     instant the selector is invoked (BEFORE the overlay activates); if it's a
     supported browser, target that one.
  2. Simpler v1: probe the running supported browsers, collect their front-window
     URLs, and use the result ONLY if exactly one is a localhost URL (unambiguous);
     otherwise nil → fallback.
  Pick one (note which); querying the browser app directly is what makes either work.
- Returns an optional URL string; all failure modes → nil (never throw into the
  record path).

**Verify + report:** with a localhost dev server open in Safari and in a Chromium
browser, confirm the reader returns the right `localhost:<port>` URL (and the TCC
prompt appears once per browser, and a denial returns nil cleanly). Report the
strategy chosen + that it works, before wiring. **Pause here.**

## Part 2 — port extraction (localhost-only)
`portForLocalhostURL(_:) -> Int?`: parse via `URLComponents`; return `port` ONLY
when `host` ∈ {`localhost`,`127.0.0.1`,`::1`,`0.0.0.0`}; default the port when the
scheme implies one only if you're confident (else require an explicit port). Any
non-local host → nil. Pure + unit-tested.

## Part 3 — the port→folder map
`PreferencesStore`: add `Keys.devProjectByPort` (`vf.dev.projectByPort`), a
`[String: String]` (port-as-string → folder path) with get/set helpers, and add it
to `Keys.resettable`. `devProjectPath` stays as the global fallback.

## Part 4 — wire into Dev Mode (the fallback chain)
On Dev Mode entry / when the dev-settings menu opens (`handleDevModeEntered`):
1. If the toggle is on, async (off-main) read the URL → `portForLocalhostURL` →
   look up `devProjectByPort[port]`.
2. **Hit** → pre-fill `state.setProjectURL(folder)` and show a subtle
   "auto-detected from localhost:<port>" hint near the Project row (so it's clear
   why the folder is set, and overridable via the existing "Change…").
3. **Miss / no port / denied / off** → fall back to `devProjectPath` (today's
   behavior). Never clear an already-set folder on a failed detection.
On a Dev recording (or when the user picks a folder via "Change…" while a port was
detected), **save** `devProjectByPort[port] = folder` so it's remembered next time.
Keep updating `devProjectPath` too (global last-used unchanged).

## Part 5 — permission UX + the toggle
- Settings (App Behavior): a "Auto-match project to localhost" toggle (default on)
  that gates the whole reader. Off → never reads the browser.
- First detection triggers the system TCC prompt per browser. If denied: silently
  fall back, and don't nag — surface a one-line, dismissible explainer at most once
  ("Allow Zerro to read your browser's localhost address in System Settings ▸
  Privacy ▸ Automation to auto-match folders"), never a blocking modal.
- Re-entry with permission already granted is silent.

## Part 6 — tests
- `portForLocalhostURL`: `http://localhost:3000/x`→3000, `127.0.0.1:5173`→5173,
  `[::1]:8080`→8080; `https://example.com`→nil, `localhost` (no port)→per your
  rule, garbage→nil.
- Map persistence: set/get/reset round-trips; `devProjectByPort` in `resettable`.
- Fallback chain (reader stubbed): hit → pre-fills mapped folder; miss/denied/off →
  uses `devProjectPath`, never clears a set folder.
- The reader itself: stub the AppleScript layer; the URL→port→lookup wiring is
  tested even though the live Apple Event isn't.

## Part 7 — live E2E (STOP)
1. Serve a site on `localhost:3000`; enter Dev Mode → grant the Automation prompt →
   pick the project folder once; record.
2. Re-enter Dev Mode on `localhost:3000` → folder is **pre-filled** automatically
   with the hint. Change the served port to `:5173` → it's a fresh mapping (no
   wrong folder); map it once → remembered.
3. Toggle the setting off → no browser read, manual/last-used only. Deny the TCC
   prompt → silent fallback, Dev Mode still fully works.
4. Non-localhost tab frontmost → nothing read, no folder change.

## Acceptance criteria
- Recording a previously-mapped localhost port pre-fills its folder with no click;
  a new port is learned on first folder pick; the "Change…" override still works.
- Reading is Dev-Mode-only, localhost-only, off-main, never blocks recording, and
  never logs/transmits a URL. Toggle off or TCC-denied → byte-identical to today.
- Entitlement + usage string in place; the per-browser Automation prompt appears
  once and a denial degrades gracefully. Firefox documented as unsupported.
- Build + tests green; normal mode and BYOK/managed dispatch untouched.

## Notes
- Privacy framing matters for trust: this reads the user's active browser URL. Keep
  it opt-in, localhost-only, ephemeral (use the port, discard the URL), and never
  persist anything but `port → folder`.
- Future (out of scope): disambiguate by the browser **window under the selection
  region** (more precise than "the one running browser with a localhost tab");
  Firefox via the AX address-bar read.
- This is the last big Phase 3 item besides the custom-command escape hatch.
