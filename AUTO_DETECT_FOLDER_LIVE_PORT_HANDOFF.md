# Handoff: Auto-Detect Project resolves to a STALE folder (port→folder map never self-corrects)

## TL;DR for the implementer

When the area-selector overlay opens in Dev Mode with **Auto-Detect Project** ON, it correctly
detects the browser's `localhost:<port>` (the green `localhost:3000` badge proves the HIT branch
fired) **but the project folder it fills in is the wrong/stale one** — whatever folder was *last
manually mapped* to that port. There is currently **no mechanism that maps a port to the folder
actually serving it right now**, so once `devProjectByPort["3000"]` points at the wrong project, it
can never self-correct on its own. The user wants: *on overlay open, set the folder to the project
that is genuinely serving the detected localhost port.*

The fix is to add **live port→folder resolution** (find the process listening on the detected port
and derive its project root from its working directory), use that as the authoritative answer, and
treat the learned `devProjectByPort` map as a fallback/cache only — refreshing it whenever live
resolution disagrees.

---

## Repo / files (all under `apps/desktop/Zerro/`)

| Area | File | What's there |
|---|---|---|
| Detection orchestration | `Surfaces/AreaSelector/AreaSelectorWindowController.swift` | `beginLocalhostFolderDetection(for:)` (~L1026), folder-picker `presentFolderPicker` (~L1139), `rememberLocalhostPortMapping` (~L1088), seeding in `present()` (~L140) |
| Pure URL→port→decision wiring | `Services/Dev/BrowserURLReader.swift` | `portForLocalhostURL` (~L150), `resolveFolder(forURL:folderForPort:)` (~L176), `LocalhostFolderResolution` enum (~L162) |
| Persisted map + state | `Preferences/PreferencesStore.swift` | `devProjectByPort` (~L216), `projectURL(forPort:)` (~L221), `setProjectURL(_:forPort:)` (~L228), `devProjectURL` last-used (~L164) |
| Overlay state | `Surfaces/AreaSelector/AreaSelectorState.swift` | `setAutoMatchedProject(_:port:)` (~L810), `noteDetectedLocalhostPort` (~L819), `projectAutoMatchedFromPort` flag (~L763) |
| UI row + badge | `Surfaces/AreaSelector/AreaSelectorView.swift` | `devProjectRow` (~L1462) — renders the folder path + the green `localhost:<port>` badge |
| Tests | `ZerroTests/LocalhostAutoMatchTests.swift` | Pure-logic coverage for everything above |

---

## Current flow (what actually happens today)

1. Overlay opens → `present()` seeds the folder from `preferences.devProjectURL` (global last-used),
   then calls `beginLocalhostFolderDetection(for:)`.
2. That reads the browser's front-tab URL (AppleScript) and calls:
   ```swift
   BrowserURLReader.resolveFolder(forURL: url,
       folderForPort: { self.preferences?.projectURL(forPort: $0) })
   ```
3. `resolveFolder` extracts the port and looks it up **only** in the learned `devProjectByPort`
   dictionary:
   - **HIT** (`.autoFill(folder, port)`) → `state.setAutoMatchedProject(folder, port:)` → sets
     `state.projectURL = folder`, raises `projectAutoMatchedFromPort = true` → the green badge shows.
   - **MISS** (`.notePort`) → remembers the port; leaves the current folder untouched.
4. The map is only ever *learned* from a **manual** action: `presentFolderPicker` →
   `rememberLocalhostPortMapping` → `preferences.setProjectURL(folder, forPort: port)`.

### Why the folder is wrong

- The "port → folder" answer is a **stale cached dictionary entry**, not the project that's actually
  serving the port. If port 3000 was once mapped to `~/Desktop/old-website` and today 3000 is served
  by a *different* project, the overlay still fills in `~/Desktop/old-website`. The badge shows
  (HIT), so it *looks* like it's doing the right thing — it's confidently wrong.
- There is **no live port-introspection** anywhere in the codebase (verified: no `lsof`,
  `proc_pidpath`, pid-for-port, or cwd-of-process logic exists). So a stale entry can only be fixed
  by the user manually re-picking via **Change…** — which defeats the point of auto-detect.

### Two secondary bugs to fix while you're in here

1. **Auto-match never persists `devProjectURL`.** The manual picker writes both `state.setProjectURL`
   *and* `preferences?.devProjectURL = url` (controller ~L1167-1169). The auto-match HIT path
   (`setAutoMatchedProject`) writes **only** `state.projectURL` — it never updates the persisted
   global last-used. So an auto-matched folder isn't remembered as last-used for the next launch.
2. **Auto-match never re-learns.** Even when live resolution (added below) discovers the *correct*
   folder for the port, nothing writes it back to `devProjectByPort`, so the stale entry survives.

---

## Desired behavior

On overlay open in Dev Mode with Auto-Detect ON, and a detected `localhost:<port>`:

1. **Resolve the folder LIVE** — find the process listening on `<port>` and derive its project root
   from that process's working directory. This is the authoritative answer.
2. Fill the folder with the live result, show the `localhost:<port>` badge, run the git-repo check.
3. **Refresh the cache**: write the live folder to `devProjectByPort[port]` and to `devProjectURL`.
4. **Fallbacks** (in order) when live resolution can't answer:
   - learned `devProjectByPort[port]` (today's behavior),
   - else keep the current last-used folder (a miss must never *clear* a set folder — preserve
     `testAutoMatchMissNeverClearsFolder`).

---

## Suggested implementation

### 1. Add a live port→folder resolver (new, pure-ish service)

Create `Services/Dev/LocalhostPortResolver.swift` with a function that, given a port, returns the
project root of the process serving it, or nil. Reference approach (macOS):

- Find the listening pid: shell out to `lsof -nP -iTCP:<port> -sTCP:LISTEN -t` (returns pid(s)),
  **or** use `proc_listpids` + `proc_pidfdinfo` for a no-shell path. `lsof` is simplest and is the
  pattern the team already uses elsewhere (`Process()` shows up in `PermissionsManager` and
  `DevAgentBinaryResolver`).
- Get that pid's working directory: `lsof -a -p <pid> -d cwd -Fn` (the `n` field after `fcwd`), or
  `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, …)`.
- Walk up from the cwd to the nearest project root marker (`.git`, then `package.json`, etc.) so a
  dev server started in a subdirectory still resolves to the repo root. Reuse whatever the git-repo
  check already considers a repo root if practical.

Keep all I/O **off the main thread** and **fail-open** (any error → nil), mirroring the existing
`BrowserURLReader` discipline. Budget a tight timeout — this runs on the hotkey→overlay path.

> Note for the implementer: `lsof` cwd for the listener may be the **shell/parent** that launched the
> dev server rather than the project dir in some setups (e.g. a server spawned by a long-lived
> terminal). Prefer the project-root walk above, and if the cwd is a home dir or `/`, treat it as a
> miss and fall through to the cache. Validate against the user's real setup (port 3000) before
> shipping.

### 2. Extend the resolution wiring

Thread the live resolver into the decision. Either:

- **Option A (preferred):** add the live lookup *inside* the controller's
  `beginLocalhostFolderDetection`, before consulting the cache, and keep `resolveFolder` pure by
  passing a richer `folderForPort` closure that tries live-first then cache. Keep the enum the same.
- **Option B:** add a new `LocalhostFolderResolution` case (e.g. `.autoFillLive`) if you want the UI
  or analytics to distinguish a live hit from a cached hit. Only do this if the distinction is
  useful; otherwise reuse `.autoFill`.

### 3. Persist + re-learn on a live hit

In the `.autoFill` handling (controller ~L1064), after `state.setAutoMatchedProject(folder, port:)`:
```swift
preferences?.devProjectURL = folder                 // fix bug #1: remember as last-used
preferences?.setProjectURL(folder, forPort: port)   // fix bug #2: refresh the stale cache entry
```
Guard so this only overwrites the cache when the live result differs, to avoid needless writes.

### 4. Keep the manual path intact

`presentFolderPicker` already does the right thing (sets state, persists last-used, re-learns the
map, drops the auto flag). Leave it — it's the user's explicit override and source of truth.

---

## Tests to add / update (`ZerroTests/LocalhostAutoMatchTests.swift`)

The existing pure tests must keep passing. Add:

1. **Live-resolution precedence** — with a stubbed live resolver returning `/proj/live` and a cache
   entry `/proj/stale` for the same port, the live folder wins and the cache is refreshed to
   `/proj/live`.
2. **Live miss falls back to cache** — live resolver returns nil, cache has `/proj/cached` → folder
   becomes `/proj/cached` (today's behavior preserved).
3. **Total miss never clears folder** — live nil + cache nil → last-used folder unchanged
   (`testAutoMatchMissNeverClearsFolder` stays green).
4. **Auto-match persists last-used** — after an auto-fill, `preferences.devProjectURL` equals the
   matched folder (covers bug #1).
5. **Auto-match refreshes the map** — after a live auto-fill that disagreed with the cache,
   `preferences.projectURL(forPort:)` returns the live folder (covers bug #2).
6. Keep the new `LocalhostPortResolver` parsing logic pure and unit-test the
   `lsof`-output → cwd → project-root extraction with fixture strings (no live sockets in CI).

Make the live resolver injectable (a closure/protocol) so tests never touch real ports or `lsof`.

---

## Constraints / gotchas

- **Opt-in + Dev-only gate stays.** Everything still lives behind
  `preferences.devAutoDetectProject == true` and `state.isDevMode`. Off → byte-identical to today.
- **Privacy boundary unchanged.** Only loopback hosts with an explicit port resolve
  (`portForLocalhostURL`); don't widen that.
- **Off the hotkey→overlay hot path.** `lsof`/process introspection must run async with a tight
  timeout and fail-open; never block `present()`.
- **Don't regress the overlay-level / TCC-prompt dance** in `beginLocalhostFolderDetection`
  (the `.normal`-level drop while the Automation prompt is pending).
- **A miss never clears a set folder** — this invariant is explicitly tested; preserve it.
- Match house style: heavy doc-comments explaining *why*, pure testable cores, injected I/O.

## How to verify manually

1. Map port 3000 to project A via Change… (learns `devProjectByPort["3000"] = A`).
2. Stop A. Start project **B** on port 3000. Open the overlay in Dev Mode with Auto-Detect ON.
3. **Expected:** folder shows **B**, badge shows `localhost:3000`, and `devProjectByPort["3000"]`
   is now B. (Today it wrongly shows A.)
