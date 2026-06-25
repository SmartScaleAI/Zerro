# Dev Mode — Permission Tiers & Unrestricted Warning (Implementation Spec)

**Status:** Ready for implementation · **Created:** 2026-06-24
**Scope:** macOS app (`apps/desktop`). No backend changes.

---

## 1. Goal

Replace the two separate Dev-Mode permission controls with **one three-tier picker**
that reads as a single "how much do I trust the agent" dial. Two of the tiers
(**Ask Permission**, **Auto-Approve**) confine the agent to the project so its work is
safe and reversible; the third (**Unrestricted**) removes the fences for power users and
is gated behind a warning.

This must hold for **all three supported agents — Claude Code, Codex, Cursor.**

The headline experience (describe a change → watch it apply live via hot reload) and the
ability to run commands like `npm install` must keep working in Ask Permission and
Auto-Approve. The fences only block reaching **outside the project**.

---

## 2. The three tiers

| Tier | Reviews before running? | Runs commands (npm install, build)? | Confined to repo? |
|------|--------------------------|--------------------------------------|--------------------|
| **1. Ask Permission** *(default)* | Yes — shows the plan, you approve | Yes, after you approve | Yes (fenced) |
| **2. Auto-Approve** | No — runs live | Yes | Yes (fenced) |
| **3. Unrestricted** | No | Yes | **No** — can act outside the repo |

Read top to bottom, each step trades safety for autonomy: 1→2 drops the review pause,
2→3 drops the fence.

Two underlying dimensions are being collapsed into this one control:
- **Review gate** (today's `DevPermissionMode.askPermission` vs `.autoApprove`) — a
  Zerro-side pause that shows the generated plan before dispatch. Only **Ask Permission**
  has it.
- **Containment** (the fences in §5) — applied to **Ask Permission + Auto-Approve**;
  removed for **Unrestricted**.

> Note: the review gate is Zerro-side behavior, not a CLI flag. Ask Permission and
> Auto-Approve therefore use the **same** agent invocation; they differ only in whether
> Zerro pauses for approval before dispatching.

---

## 3. Settings-model change

Today there are two settings:
- `PreferencesStore.devPermissionMode` : `DevPermissionMode` (`.askPermission` / `.autoApprove`) — the review gate.
- `DevAgentPermission` (`.editsOnly` / `.allowCommands`) — the agent capability/shell posture.

**Collapse to a single enum** driving both axes. Suggested:

```swift
enum DevPermissionTier: String, CaseIterable, Sendable {
    case askPermission   // review gate ON,  fenced
    case autoApprove     // review gate OFF, fenced
    case unrestricted    // review gate OFF, UNfenced
}
```

- Persist as `PreferencesStore.devPermissionTier` (migrate the old `devPermissionMode`
  raw value: `askPermission → .askPermission`, `autoApprove → .autoApprove`).
- Keep the existing `DevAgentPermission` mapping internally if convenient, but it is now
  **derived** from the tier (see §6), not a separate user choice. Both Ask Permission and
  Auto-Approve allow commands (fenced); Unrestricted allows commands (unfenced).
- Update the dev-settings picker UI (`AreaSelectorView` / `AreaSelectorWindowController`)
  from 2 rows to 3 rows.

---

## 4. Defaults & persistence

- **Starting default = `askPermission` for everyone.** (Changes today's `.autoApprove`
  default. We have no existing users, so migrate all to the new default — do not preserve
  the old `.autoApprove` default.)
- After first use, **remember the last-used tier** (persisted, as today).
- Selecting **Unrestricted** switches immediately (no separate confirm at selection time —
  the gate is at record time, see §7). Show a small inline ⚠ caption on the Unrestricted
  row, e.g. *"Confirms each time you record."*

---

## 5. The fences (what "fenced" means)

Applied to **Ask Permission + Auto-Approve**; **removed** for Unrestricted. Three layers,
all enforced by Zerro (not by trusting the agent):

### 5a. No MCP  *(uniform intent, per-agent flag)*
The agent loads **zero MCP servers**, removing the pre-wired database/API-connector path.
- **Claude Code:** add `--strict-mcp-config` and pass **no** `--mcp-config` (so no user
  `~/.claude.json` / project `.mcp.json` servers load).
- **Codex:** add `--ignore-user-config` (ignores `~/.codex/config.toml`, so no user MCP
  servers load). Codex `exec` also auto-cancels MCP calls on closed stdin already.
- **Cursor:** run against a config without `mcp.json` (or `agent mcp disable`), and do
  **not** pass `--approve-mcps`.

### 5b. Scrubbed environment  *(Zerro-side, uniform)*
Today `DevAgentProcessExecution.spawnEnvironment` forwards the **full** environment
(`ProcessInfo.processInfo.environment`). Change to an **allowlist**: pass only what the
agent + node/npm need, and the selected agent's own auth var. Strip everything else
(DB URLs, cloud creds, unrelated API keys/tokens) so a command has **no credentials** to
mutate an external system.

- **Keep:** `PATH` (the existing carefully-built value), `HOME`, `USER`, `SHELL`,
  `LANG`, `LC_*`, `TMPDIR`, `TERM`, and the **active agent's** auth var only
  (Claude → `ANTHROPIC_API_KEY`; Codex → `OPENAI_API_KEY`/`CODEX_API_KEY`;
  Cursor → its token, if env-based). Most agents read auth from their own config dir
  (`~/.claude`, `~/.codex`, `~/.cursor`), so the auth var may be unnecessary — keep it
  only if present.
- **Strip:** everything else, especially `DATABASE_URL`, `*_DB_*`, `AWS_*`, `GCP_*`,
  `GOOGLE_*`, `STRIPE_*`, generic `*_SECRET` / `*_TOKEN` / `*_API_KEY` not belonging to
  the active agent.
- The **dev server** (run separately by Zerro, e.g. `ManagedDevServer`) keeps its own
  environment — this scrub is on the **agent** process only, so the live preview is
  unaffected.

### 5c. Filesystem confinement to the repo  *(see phasing in §8)*
Guarantees every file change is inside the project, so the git checkpoint is a true undo.
Because macOS Seatbelt sandboxes **cannot be nested**, the reliable cross-agent approach
is: **disable each agent's own sandbox and wrap the process in one Zerro-owned
`sandbox-exec` (Seatbelt) profile** that denies file-writes outside the project dir
(allow: the repo, `$TMPDIR`, and the agent's own config/cache dirs). Network is left
**open** in v1 (so `npm install` works); external-side-effect safety in v1 comes from
5a + 5b (no connectors, no credentials). Network allowlisting is deferred (§8).

> Honesty note: until 5c ships, "Confined to repo = Yes" for tiers 1–2 means *no external
> connectors, no credentials, and in-repo changes are git-revertable* — not yet OS-hard
> filesystem confinement. If 5c is deferred past launch, word the UI as
> *"changes are tracked and reversible"* rather than *"physically confined."*

> **Keychain carve-out (post-launch, June 2026).** The wrapper is INCOMPATIBLE with
> agents that authenticate via the macOS **Keychain**. When Zerro (a GUI app) spawns the
> agent under `sandbox-exec`, securityd denies the sandboxed child access to the
> login-Keychain item, so the agent gets no token and its own API request returns **401
> "Failed to authenticate."** This is a securityd ACL policy, not a file-write deny — the
> Seatbelt *profile cannot fix it* (live-verified: every filesystem/env variation of the
> profile — full repo writes, all of `$HOME`, the scrubbed env, a detached tty — still
> reads the Keychain fine from a shell; only the GUI-app sandbox spawn trips it). So a
> Keychain agent (**Claude Code**, the `Claude Code-credentials` item) runs **UNWRAPPED**
> on the fenced tiers, with §5a + §5b + the git checkpoint as containment (exactly this
> "changes are tracked and reversible" posture) and **network left open** (the §8 egress
> filter rides on the wrapper's Seatbelt rule, so it's skipped too — an env-var-only proxy
> is bypassable and would only risk the auth path). Agents that read a **file** token
> (**Codex** `~/.codex/auth.json`, **Cursor** `~/.cursor`) are unaffected — the sandbox
> permits the read — so they KEEP the wrapper + egress filter. The pivot is
> `DevAgentEntry.credentialStore` (`DevAgentRunner.run`).

---

## 6. Per-agent CLI mapping

Base args are unchanged from the current registry. The tier changes the
permission/sandbox flags, the MCP flags (5a), whether the env is scrubbed (5b), and
whether the process is wrapped (5c). The **review gate** (Ask Permission) is Zerro-side
and identical at the CLI level to Auto-Approve.

### Claude Code  (`claude -p --output-format stream-json --verbose`)
| Tier | Permission/sandbox flags | MCP | Env | Wrapper (5c) |
|------|--------------------------|-----|-----|--------------|
| Ask Permission | `--permission-mode bypassPermissions` | `--strict-mcp-config` (none) | scrubbed | yes |
| Auto-Approve   | `--permission-mode bypassPermissions` | `--strict-mcp-config` (none) | scrubbed | yes |
| Unrestricted   | `--permission-mode bypassPermissions` | MCP enabled (no `--strict-mcp-config`) | full | no |

> `bypassPermissions` is used in the fenced tiers because it won't hang headless and lets
> commands run; the **Zerro fences** (no-MCP + env-scrub + wrapper) provide the
> containment that `bypassPermissions` itself doesn't. (Claude Code's native sandbox only
> covers Bash, so it can't be relied on for file/MCP confinement.)

### Codex  (`codex exec --skip-git-repo-check --color never`)
| Tier | Sandbox flag | MCP | Env | Wrapper (5c) |
|------|--------------|-----|-----|--------------|
| Ask Permission | `--sandbox danger-full-access` | `--ignore-user-config` | scrubbed | yes |
| Auto-Approve   | `--sandbox danger-full-access` | `--ignore-user-config` | scrubbed | yes |
| Unrestricted   | `--sandbox danger-full-access` | user config (MCP) | full | no |

> Native `--sandbox workspace-write` confines files but forces **network off** on macOS
> (so `npm install` can't fetch). To keep installs working under the Zerro wrapper, run
> Codex with its own sandbox off (`danger-full-access`) and let the wrapper confine it.
> Without the wrapper (if 5c is deferred), prefer `workspace-write` for the fenced tiers
> and accept that network installs won't run under Codex on macOS — a known limitation.

### Cursor  (`cursor-agent -p --output-format stream-json --trust`)
| Tier | Command flag | MCP | Env | Wrapper (5c) |
|------|--------------|-----|-----|--------------|
| Ask Permission | `--force` | no `mcp.json` / `agent mcp disable` | scrubbed | yes |
| Auto-Approve   | `--force` | no `mcp.json` / `agent mcp disable` | scrubbed | yes |
| Unrestricted   | `--force` | MCP enabled | full | no |

> Cursor's plain `-p` rejects shell, which would block `npm install`. The fenced tiers use
> `--force` (runs commands) and rely on the Zerro wrapper for confinement (Cursor's own
> sandbox left off to avoid Seatbelt nesting).

---

## 7. Unrestricted warning dialog

A single confirmation **at record time** — the moment that actually matters.

**Trigger:** the user presses Record while the active tier is **Unrestricted** — **every
time**, even if previously confirmed — UNLESS the "Don't show again" preference is set.
(No separate dialog at selection time; selecting Unrestricted just switches with the ⚠
caption from §4.)

**Behavior:**
- **Cancel** → abort; the recording does not start. Tier stays Unrestricted (they can
  reselect another tier).
- **Proceed** → start the recording/dispatch in Unrestricted.
- **Checkbox: "Don't show this warning again"** → only takes effect if they **Proceed**.
  When set, persist `PreferencesStore.devUnrestrictedWarningSuppressed = true`, which
  suppresses this dialog from then on. (Ignored if they Cancel.)

**Suggested copy:**
> **Title:** Run in Unrestricted mode?
>
> **Body:** Unrestricted mode lets the agent do anything on your computer — run any
> command, access the internet, and make changes **outside this project**, including to
> databases, deployments, and files Zerro **cannot undo**. Only continue if you fully
> trust the agent with this task. (Ask Permission and Auto-Approve keep the agent inside
> this project, where changes can be reverted.)
>
> ☐ Don't show this warning again
>
> **[Cancel]**  **[Proceed in Unrestricted]**   ← Cancel is the default/safe button.

**New preference key:** `vf.dev.unrestrictedWarningSuppressed` (Bool, default `false`).
Resettable via the existing dev-settings reset path.

---

## 8. Phasing

**Phase 1 (recommended for launch):**
- §3 settings collapse + 3-row picker.
- §4 defaults (Ask Permission for all) + persistence.
- §5a No-MCP + §5b env-scrub on Ask Permission / Auto-Approve.
- §7 Unrestricted record-time warning + suppress checkbox.
- For §5c, ship the **Zerro Seatbelt wrapper** if feasible; if not, launch with the
  native-sandbox fallback noted per-agent in §6 and use the softer UI wording from §5c.

This already neutralizes the "delete my database" scenario (no connector + no creds).

**Phase 2 (fast-follow):**
- §5c Zerro Seatbelt wrapper across all three agents (hard filesystem confinement → makes
  "confined to repo" literally true and lets §6 standardize on "native sandbox off +
  wrapper").
- **Network allowlist** (proxy or Seatbelt network rules): allow each agent's API host +
  package registries, deny everything else — closes the residual that a command could
  reach an external host. Until then, 5a + 5b are the safeguard.

---

## 9. Acceptance criteria

- Picker shows 3 tiers; fresh install starts on **Ask Permission**; last-used tier is
  remembered.
- In **Ask Permission** and **Auto-Approve**, for **each** of Claude Code / Codex / Cursor:
  - "describe a change → file edits apply → dev server hot-reloads" still works.
  - A request that needs MCP (e.g. "search my Notion") completes with the agent reporting
    it can't — **no hang**.
  - A request to mutate an external system (e.g. "delete my database") makes **no external
    change** and the run completes — verified by (a) no MCP tools present and (b) no DB/
    cloud creds in the spawned env.
  - `npm install <pkg>` succeeds (network open in v1).
  - (Phase 2 / if 5c shipped) a write to an absolute path **outside** the repo fails.
- **Unrestricted**: pressing Record shows the warning **every time**; Cancel aborts;
  Proceed runs; checking "Don't show again" + Proceed suppresses it on subsequent records.
- Unit tests: tier→flags mapping per agent (extend `DevAgentRegistryTests`); env-scrub
  allowlist (keeps PATH/auth, drops a planted `DATABASE_URL`); default/migration logic;
  warning-suppression flag gating.

---

## 10. Known limitations / notes

- **Codex network on macOS:** `workspace-write` forces network off (config toggle is
  bugged off upstream). Hence the wrapper approach for installs. Re-verify against the
  bundled `codex` version.
- **Seatbelt nesting:** never run the Zerro `sandbox-exec` wrapper *and* an agent's own
  Seatbelt sandbox simultaneously — the inner one fails with `Operation not permitted`.
  The wrapper path requires each agent's native sandbox **off** (already reflected in §6).
- **CLI drift:** all flags verified against current `--help` (June 2026) for each CLI;
  re-check on dependency bumps. Existing registry comments already pin versions.
- **Files / paths to touch:** `DevAgentRegistry.swift`, `DevAgentRunner.swift`
  (`spawnEnvironment`, wrapper), `PreferencesStore.swift` (tier enum + default + new
  flag + migration), `AreaSelectorView.swift` / `AreaSelectorWindowController.swift`
  (3-row picker + dialog), `DevAgentRegistryTests.swift` / `DevPromptTests.swift` (tests).
