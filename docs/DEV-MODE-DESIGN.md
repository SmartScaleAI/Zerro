# Dev Mode — design & decisions (Zerro desktop)

Status: **implementation-ready.** All major design questions are decided below.
A handful of items are explicit **taste calls** (marked ★) where the default is
chosen but easily overridden. The phased plan at the end has per-phase acceptance
criteria.

## What it is

A new recording mode for the Zerro macOS app. The user records a region of their
screen (typically their site/app on `localhost`) and narrates the changes they want
— "make this header sticky, change the CTA to teal." On stop, Zerro turns the
recording into a precise, repo-scoped coding instruction and hands it to the user's
own coding agent (Claude Code / Codex / Cursor), which edits files on disk. The
user's dev server hot-reloads, so they watch the change land without touching the
keyboard.

The end-goal experience: **talk → stop → watch your site change.**

## Read first (existing pieces this builds on)

- `apps/desktop/Zerro/ZerroApp.swift` — global hotkey (`KeyboardShortcuts`).
- `apps/desktop/Zerro/Surfaces/AreaSelector/AreaSelectorView.swift` /
  `AreaSelectorState.swift` / `AreaSelectorWindowController.swift` — recording toolbar
  + mouse-monitor hit-testing.
- `apps/desktop/Zerro/Capture/RecordingSession.swift` — ScreenCaptureKit capture +
  AVAssetWriter; clock anchor (first sample buffer).
- `apps/desktop/Zerro/Processing/ProcessingPipeline.swift` — audio isolation, ~5fps
  frame extraction, manifest sidecar.
- The `Interleaver` (frames + transcript + clicks merge) — the alignment engine we
  extend.
- `apps/desktop/Zerro/Services/ModelRegistry.swift` — pattern for `DevAgentRegistry`.
- `apps/desktop/Zerro/Services/PromptGenerationSystemPrompt.swift` and
  `supabase/functions/generate/prompt.ts` — the **two** prompt definitions that both
  need a `mode:"dev"` variant.
- `apps/desktop/Zerro/Services/ArtifactParser.swift` — `agent_prompt` parsing.
- `apps/desktop/Zerro/Surfaces/Pill/PillView.swift` — dispatch/edit/diff states.
- `apps/desktop/Zerro/Observability/Analytics.swift` — metadata-only analytics
  (§14.5 rules; mirror for Dev Mode events).

## Core concept: Zerro is the eyes, the agent is the hands

In normal mode the `agent_prompt` is built for a **blind** external agent and must
verbalize everything. In Dev Mode the agent **has the repo** (runs with the project
as `cwd`), so Zerro = **eyes** (turn what was seen + said into a precise spec) and
the agent = **hands** (find the files, write the edit). The prompt is the handoff.

---

## 1. Interaction design

Standalone **toggle on the left** (a mode switch, not a setting). Flipping it on grows
the settings cluster from `model · mic · record` to
`model · mic · agent · folder · record`. No popover, no nested menus.

- Agent chip pre-filled by auto-detect (§2) → usually a confirmation.
- Folder chip starts in an attention state ("Select folder," amber/dashed) until set.
- **Validation on Record**: no agent or no folder → block + inline message. Replaces
  the first-run popover as the dead-end guard.
- Folder is remembered (globally last-used in v1; port-keyed in Phase 3, §5).

Implementation: add `isDevMode`, `selectedAgentID`, `projectURL` to
`AreaSelectorState`; render chips + hit-test in `AreaSelectorWindowController`'s mouse
monitor like the existing model/mic dropdowns.

Overflow (Phase 4): when toolbar width exceeds the selection width, collapse the
**model + mic** chips to icon-only with hover tooltips (they're set-and-forget); keep
**agent + folder** labeled (Dev-Mode-critical state); record button always labeled.

## 2. Agent execution model

CLI-agnostic. First-class adapters: **Claude Code** (`claude -p`, JSON stream),
**Codex** (`codex exec`), **Cursor** (`cursor-agent -p --force --output-format json`;
known `-p` hang → robust timeout, §9). Plus a **custom-command escape hatch**.

`DevAgentRegistry` (modeled on `ModelRegistry`): each entry is declarative data —
executable, prompt-passing method (arg/stdin/`--message`), auto-approve flag,
working-dir handling, output parser (json|text). A `DevAgentRunner` protocol does the
`Process` spawn, so a future first-party API agent loop is a clean substitution.

Auto-detect via `which claude codex cursor-agent` through a **login shell**; show only
installed; pre-select recommended; none installed → empty state with install links.
Auth stays each CLI's problem.

## 3. The record → change pipeline

1. Record the region (narrate changes).
2. Stop (hotkey, or auto-stop at ~180s).
3. Zerro writes the prompt — process, transcribe (Whisper), generate with `mode:"dev"`
   (§6) + anchor resolution (§7).
4. **Git checkpoint** (§4).
5. Agent runs in the repo — spawn CLI with `cwd`=project, auto-approve on, stream into
   the pill (§9).
6. Localhost hot-reloads — agent writes real files; Zerro never drives the browser.
7. Review/undo — pill shows diff stat + one-click revert.

Divergence from normal mode is at 3→4: normal copies `agent_prompt` to clipboard and
stops; Dev Mode never touches the clipboard and dispatches to the runner.

## 4. Safety model — git checkpoint (DECIDED)

Principle: auto-submit, **checkpoint first, one-click revert**; guardrail invisible
until needed.

Mechanics (v1):
- **Require a git repo** for Dev Mode (clean constraint; non-git → temp-dir snapshot
  is Phase 4).
- Checkpoint **without polluting branch history**: capture tracked + index state via
  `git stash create` and record the returned commit SHA; capture **untracked** files
  by copying them into Zerro's working dir (stash-create omits untracked). This snapshot
  represents the exact pre-agent state — **including** any uncommitted/dirty work.
- The agent then edits the working tree directly.
- **Revert** = restore tracked files from the stash-create commit (`git restore
  --source=<sha> -- .` / checkout) + restore the saved untracked files + delete any
  agent-created files not in the snapshot. Net: working tree returns to exactly the
  pre-run state, the user's uncommitted work intact, branch history untouched.
- **Dirty tree**: never folded into a commit — it lives only in the snapshot, so revert
  restores it faithfully. We do **not** auto-stash the user's work away before the run.
- **Diff surface**: pill shows `N files changed (+x −y)` from
  `git diff --stat <checkpoint> -- <worktree>`; a "view diff" affordance opens the full
  diff in the user's editor/terminal. v1 = stat only.

## 5. Project binding

Explicit binding is the source of truth — never silently target an inferred repo (a
wrong guess = unattended edits to the wrong codebase). User picks a folder; remembered.

Magic layer (Phase 3): read the frontmost browser URL via **AppleScript / Apple Events**
(more reliable than the AX API) at recording start, persist a `port → folderURL` map in
`PreferencesStore`, and pre-fill the folder chip when the recorded `localhost` port is
known. Best-effort and never blocking. **Caveats (research-confirmed):** this triggers a
one-time **Automation** TCC consent prompt per browser; **Firefox exposes no usable
URL** (degrade gracefully); cache consent and debounce. Same browser-URL signal feeds
route context to the prompt (§6). See §11 for the full correction.

## 6. The Dev Mode prompt

Describe **intent + anchors**, not code. The strongest anchor is **visible text** (the
agent greps the string). Output shape (`agent_prompt` body):

```
Goal: <one line, scoped to a page/route>

Changes:
1. <visible-label anchor + current → desired>
2. ...

Scope: <touch / don't touch; match existing style; no unrelated refactors>
```

Plus: **route context** (`localhost/...` path), a **runtime note** (live dev server +
hot reload → minimal targeted edits, don't scaffold/restart), and an **enumerated
checklist** ordered by when each change was said, filler stripped.

Implementation: a `mode:"dev"` flag swaps the system prompt + expected artifact shape
in **both** `PromptGenerationSystemPrompt.swift` and `generate/prompt.ts`. v1 hands the
agent **text only**; keyframes to vision-capable agents is Phase 4.

★ **Vague-intent prescriptiveness (DECIDED, taste call).** Rule: resolve a qualitative
ask into the **smallest concrete change** that satisfies the visible intent, prefer
reversible CSS-level changes over structural ones when ambiguous, and always preserve
the user's **original phrasing verbatim** in a "user said: …" line so the agent has the
raw intent as a tiebreaker. If an ask is too vague to map to any concrete change **and**
has no element anchor, emit it as a low-confidence note rather than inventing a change.

## 7. Deixis resolution — the engine

A deictic reference = a moment where the user **said** a pointing word and the cursor
was **resting on** something. Resolve the coincidence to the element's visible text.

### Signals (and the gap)

- **Transcript** — word-level Whisper timestamps (`word_timestamps`).
- **Cursor** — the gap: clicks are too sparse (pointing is usually a hover). Add a
  continuous cursor track by **polling `NSEvent.mouseLocation` at ~30Hz** (research-
  confirmed more reliable than a mouse-moved monitor, and needs **zero permission** —
  unlike keyboard/click capture, which would pull in Input Monitoring). Clicks remain a
  high-confidence layer.
- **Frames** — existing ~5fps keyframes.

### Correctness plumbing

- **Clock sync** — Whisper (audio-relative), cursor (host time), frames (video PTS) all
  rebase to the `RecordingSession` first-sample-buffer zero.
- **Coordinate mapping** — global screen-space cursor → recorded cropped-region pixel
  space (same crop/flip/scale as the selector). A wrong transform points at the wrong
  element.

### Alignment algorithm

1. Scan the timestamped transcript for **referring expressions** (deictics + definite
   noun phrases).
2. Open a window biased **earlier** than the phrase (pointing precedes speech):
   `[start − 800ms, end + 200ms]`.
3. Target point priority: **click > hover-dwell > last-known**; dwell = the stillest
   cluster in the window. Stillness → a confidence input.
4. Nearest keyframe to that moment → the triple (phrase, point, frame).

### Point + frame → label (element-ID contract, DECIDED)

- Composite a **crosshair marker** on the keyframe at the cursor point.
- **OCR** the region near the point with Apple's **Vision framework**
  (`VNRecognizeTextRequest`, on-device, no dependency) to pin exact strings.
- The multimodal model (the **same generation call**, fed marked frame + nearby strings
  + narration) returns, per reference, a structured anchor:

```
{ label: string|null,           // verbatim visible text
  type:  button|link|text|image|icon|input|container,
  region: header|nav|hero|sidebar|main|footer,
  current_state: string,        // e.g. "blue bg, 14px"
  confidence: 0.0–1.0,
  alt_candidates: [string] }
```

Native-app targets could later use the AX API to read the element under a point; for
browser targets, marker + OCR + vision is v1.

### Confidence & fallback policy (DECIDED)

Per-reference confidence drives dispatch:
- **High** (click, or clear dwell whose OCR label matches) → stated as fact in the
  prompt; **dispatch proceeds automatically.**
- **Medium** (dwell but no clean label, or OCR/vision partial agreement) → hedged in the
  prompt as "likely the X" **with** disambiguating context (region + nearby text) so the
  agent can self-verify; still auto-dispatches.
- **Low** (said "this" mid-move, empty space, OCR/vision disagree) → **pauses at a
  pre-dispatch confirm** in the pill (§8) showing the resolved anchors; the run waits for
  a one-glance confirm instead of guessing.

Net rule: **all-high/medium → dispatch immediately (the magic path); any low → brief
confirm.** A bad alignment degrades to "ask," never "confidently edit the wrong thing."

### Where it lives

An extension of `Interleaver`: it grows a cursor track, word-level timing, the deixis
scan, and marker compositing; its output gains the resolved-anchor list the Dev Mode
prompt generator (§6) weaves in.

## 8. Pill state machine (DECIDED)

Existing: `processing → transcribing → writingPrompt`. New Dev Mode tail:

```
checkpointing            (brief)
→ confirmAnchors?        (ONLY if a low-confidence anchor exists, §7)
→ dispatching
→ agentRunning           (streamed substatus + elapsed; §9)
→ done    | failed
```

- `agentRunning` substatus from the runner: "reading files", "editing <file>",
  "running", or a generic "working…" for text-only agents, plus elapsed time.
- `done`: "N files changed (+x −y) · [Revert] [Done]". Revert = §4 restore.
- `failed`: short stderr tail + "[Revert] [Retry]". **No auto-revert** — leave the
  partial edits and let the user choose (revert restores cleanly via §4).

## 9. Agent runner internals (DECIDED)

- Spawn via `Process`, stdout/stderr piped, **line-buffered**. JSON-stream agents →
  parse events to pill substatus; text agents → spinner + tail of last line.
- **Timeouts**: overall wall-clock cap (default **5 min**, configurable) **and** an
  inactivity timeout (no output **60s** → presumed hung). On either: SIGTERM, then
  SIGKILL after a short grace; mark `failed`; this is the Cursor `-p`-hang safety net.
- **Errors**: non-zero exit → `failed` with stderr tail; no auto-revert.
- **Concurrency**: one Dev Mode run at a time (mirror the `generation_slots` cap-1
  idea); block/serialize a second dispatch while one runs.
- **Permissions**: auto-approve flag comes from the registry entry; the agent runs with
  the user's full perms inside their repo — the git checkpoint is the containment.

## 10. Billing, auth & analytics (DECIDED)

- **Billing**: the execution step runs on the user's **own** agent subscription/auth —
  **outside** Zerro's managed credits. Only the recording→prompt step (step 3) uses
  Zerro's model (managed or BYOK), metered as today via the toolbar model chip.
- **Analytics** (metadata only, behind the existing opt-out gate, never content/path/
  email per §14.5): `dev_mode_toggled`, `dev_dispatch_started` (agent_id),
  `dev_run_succeeded`/`dev_run_failed` (reason, duration_ms, files_changed),
  `dev_anchor_resolution` (count + confidence histogram), `dev_revert_used`. These
  quantify whether the loop actually works and where it breaks.

## 11. Research-driven risk review (validation + additions)

Findings from a prior-art/competitor pass (stagewise, Onlook, Builder.io, v0,
voice-coding tools) and a macOS technical-feasibility pass. The concept itself is
validated — **no shipped tool combines temporal narration over a live demo + cursor-
grounded deixis + dispatch to a real headless agent on a real codebase.** Corrections
and additions below.

### Distribution (confirmed, unblocks everything)
Zerro is **non-sandboxed, Developer-ID, notarized, Sparkle-updated** (`ENABLE_APP_SANDBOX
= NO`). So it **can** `Process`-spawn the user's installed CLIs — the fatal "App Sandbox
blocks spawning external binaries" risk does not apply. Keep it this way; a future Mac
App Store (sandboxed) build would break Dev Mode's execution step.

### CLI spawn plumbing (hardening §2/§9)
- **PATH is stripped** for GUI-launched apps (`/usr/bin:/bin:/usr/sbin:/sbin`), so
  `claude`/`codex`/`cursor-agent`/`node` won't be found by name. Resolve the **absolute
  binary path** once (via login-shell `which`, cache it) and spawn with an explicit
  `environment`. Don't depend on the inherited PATH.
- **Auth/env**: forward needed env (`ANTHROPIC_API_KEY`, etc.); the CLIs also read their
  own config (`~/.claude`, `~/.codex`, `~/.cursor`) written by their interactive login —
  readable since non-sandboxed. Require the user to have logged into the chosen CLI once,
  outside Zerro.
- **Exact non-interactive flags** (registry entries): Claude Code `claude -p
  --permission-mode acceptEdits`; Codex `codex exec --sandbox workspace-write` (avoid the
  deprecated `--full-auto`); Cursor `cursor-agent -p --force --output-format json`.
- **Codex MCP gotcha**: `codex exec` auto-cancels MCP tool calls (closed stdin). Don't
  rely on Codex MCP servers in headless Dev Mode.

### ★ Command permission default (new decision)
Default to **edits-only** auto-approval (`acceptEdits`) — the agent changes files but
won't run shell commands unattended. Safer, and enough for the common "change my UI"
case. Offer an opt-in **"allow commands"** (→ `bypassPermissions` / `danger-full-access`)
for users who want the agent to add deps or run builds. Note the tradeoff: edits-only
means the agent can't self-verify with a build/typecheck and will abort if it needs a
command.

### Prompt quality — the #1 real-world failure (strengthen §6)
Competitors' single loudest complaint is **bad CSS** (hardcoded `h-[298px]` instead of
flex/relative). Richer input does **not** fix this — explicit constraints do. Bake into
the dev system prompt: use the project's **existing tokens/utilities/components**, prefer
**relative/flex layout over hardcoded px**, **respect dark mode + responsiveness**, and
make the **smallest** change. This was the most effective fix other tools found.

### Transcription accuracy (new, cheap, high-value)
- **Domain dictionary**: transcription mangles library/component/variable names
  ("Vercel"→"Versel"). Seed a replacement dictionary from the project's `package.json`
  deps + component file names + identifiers; apply before prompt generation.
- **Whisper word-timing is approximate** (~0.1–0.2s, worse near pauses). The early-biased
  window (§7) absorbs most slop; if tighter sync is ever needed, re-align with
  WhisperX/stable-ts. Don't assume frame-accurate word boundaries.
- **Pause tolerance**: users pause to think mid-narration; segment on intent, not silence.

### OCR needs full-res frames (constraint on §7)
`ProcessingPipeline` downsamples keyframes (~5fps JPEGs) — too low-res for reliable OCR
of 11–13px UI text. At an anchor moment, capture/retain a **native-Retina full-res**
frame for the OCR + marker step; use Vision `.accurate`. Downscaled frames silently lose
small text.

### Review gate (refine §8 confirmAnchors)
Every comparable tool ships a human review/diff gate; "the AI does exactly what you ask"
makes ambiguous input dangerous. Beyond the low-confidence `confirmAnchors` pause,
consider a brief **pre-dispatch preview** even on the high-confidence path — a 2–3s
"here's what I'll change" with a **Cancel** (auto-proceeds on timeout) — preserving the
hands-off feel while giving an escape hatch. ★ taste call.

### Self-correction loop (new, Phase 3/4)
The agent edits then exits; if it breaks the build, the user sees an error overlay
instead of their change. A follow-up loop — detect the dev-server/build/hot-reload error
after the edit and offer a one-click "fix it" re-dispatch with the error text — is a
strong value-add competitors hint at (stagewise reads the console). Out of v1 scope;
note for later.

### Smaller caveats to track
- **Editor conflict**: if the user has a file open with unsaved changes and the agent
  writes it, their editor may clobber on save. The git checkpoint protects data; warn in
  docs.
- **Transient/auth'd/JS-heavy UIs**: elements behind loading states, modals, or
  virtualized lists may not exist at dispatch time. Text-label anchoring (not coordinates)
  makes this more robust, but flag loading-state edge cases.
- **Iteration cost**: recording dispatches are token-heavy (frames+audio+files) on the
  eyes step; budget cheap re-tries / partial re-dispatch so failed runs don't feel
  expensive.
- **Privacy/secret capture**: a recording can catch on-screen secrets (env files, other
  windows). The region selection limits this; keep "what got sent" inspectable — Zerro's
  local-first / BYO-keys / no-account posture is the right trust story; lean into it.
- **Deterministic-resolution future option**: Onlook/stagewise resolve elements
  *deterministically* via the browser DOM / build-time source maps. Zerro's pixel+cursor
  approach is more general (any app, not just web) but fuzzier for web. A later
  "browser-assist" mode (read the DOM under the cursor for ground truth, fall back to
  vision) could sharpen web accuracy. Tradeoff noted, not committed.

### Permission footprint (summary)
- Screen Recording — already granted in onboarding.
- Mic — already granted (`device.audio-input` entitlement present).
- Cursor polling — **none**.
- Apple Vision OCR — **none**.
- Browser URL detection (Phase 3, optional) — **Automation** TCC, per browser; Firefox
  unsupported.
Net: Dev Mode's core adds **zero** new mandatory permissions; only the optional
port→folder convenience adds one.

---

## Phased plan (with acceptance criteria)

**Phase 1 — the loop (one agent, explicit folder, click-only anchors).**
Toggle + inline toolbar + record-time validation; explicit folder picker (remembered,
no port magic); Claude Code adapter only; `mode:"dev"` prompt producing anchored
`agent_prompt`s; **click-only** anchoring (reuse existing click data — defer the hover
track); git checkpoint + revert; pill states through `done`/`failed`.
*Done when:* recording localhost + narrating a click-anchored change ("make the 'Get
started' button teal") results in Claude Code editing the file, localhost hot-reloading,
and Revert restoring cleanly.

**Phase 2 — the magic in the prompt.**
Continuous cursor track + word-level timestamps + dwell detection + marker compositing +
Apple Vision OCR + the confidence/fallback policy (incl. the `confirmAnchors` pill
state).
*Done when:* a hover-only reference ("make *this* bigger" with no click) resolves to the
correct labeled element at high confidence, and a deliberately ambiguous reference
triggers the confirm step instead of a wrong edit.

**Phase 3 — agent-agnostic + zero-setup.**
Codex + Cursor adapters + custom-command; auto-detect dropdown; `port → folder`
association via browser-URL read for zero-click returning-user setup.
*Done when:* switching the agent dropdown routes the same recording to a different CLI,
and re-recording a known localhost port pre-fills the folder with no click.

**Phase 4 — polish.**
Icon-compact toolbar; review-before-apply mode; richer inline diff; non-git temp-dir
snapshot fallback; keyframes to vision-capable agents.
*Done when:* the toolbar stays usable on a narrow selection and a review-before-apply
preference gates writes for users who want it.

Ordering rationale: a working end-to-end loop first (Phase 1), then the deixis/prompt
quality that makes it feel magic (Phase 2), then breadth (Phase 3), then polish (4).
