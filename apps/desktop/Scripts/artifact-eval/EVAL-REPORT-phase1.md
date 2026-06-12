# Phase 1 eval report — prompt v2 (typed-artifact contract)

2026-06-11. Prompt under test: draft 6 — **LOCKED** into
`zerro-prompt-system.md` v2 and mirrored in-repo as
`Scripts/artifact-eval/prompt-v2.md` (was `prompt-v2-draft.txt` during
iteration). Fixtures: the 40 Phase 0 cases. Raw runs in
`eval-results/artifact-v2/` (gitignored).

## OUTCOME — locked, all bars pass (lock run, §2 parser with recovery tier)

Colin approved Option A (the bounded §2 recovery tier) with conditions:
exact closed-list rules in the plan's §2 ✓, recovered cases persisted as
parser tests (`parser-tests.json`, 41 cases, run via `--parser-tests`) ✓,
recovery rate reported as a fifth scorecard metric ✓. Full matrix re-run
with the amended parser:

| model | attach ≥90 | type ≥85 | validity ≥98 | recovery rate |
|---|---|---|---|---|
| **gemini-3.5-flash (DEFAULT, pooled ×3, n=120)** | **99.2%** ✓ | **100%** ✓ | **100%** ✓ | 4/91 artifacts (4.4%) |
| gpt-5.4-mini | 95% ✓ | 100% ✓ | 100% ✓ | 0 |
| gemini-3.1-pro-preview | 100% ✓ | 100% ✓ | 100% ✓ | 0 |
| claude-sonnet-4-6 | 100% ✓ | 100% ✓ | 100% ✓ | 0 |
| claude-opus-4-7 | 100% ✓ | 100% ✓ | 100% ✓ | 0 |
| gpt-5.5 | 100% ✓ | 100% ✓ | 100% ✓ | 0 |

Residual misses in the lock run, all stochastic and within bars: flash
attached on ch-04 (the this-is-broken hard case) in 1 of 3 runs; mini
under-attached 2 borderline cases in its run. Recovery only ever fires on
flash, at ~4% of its artifacts — the baseline for the
watch-this-metric rule.

Total Phase 1 API spend (iteration + validation + lock runs): ~$18.

The sections below are the pre-decision analysis, kept for the record.

---

## Final per-model results (strict §2 parsing)

All six enabled registry models, final prompt text. Flash is pooled over
3 independent runs (n=120) because its failures are stochastic; others are
single 40-case runs. `gemini-*` at thinking=low (the production default,
`config.ts` `GEMINI_THINKING_LEVEL`).

| model | attach ≥90 | type ≥85 | validity ≥98 | chat "you" | "the user" in agent_prompt |
|---|---|---|---|---|---|
| **gemini-3.5-flash (DEFAULT)** | **93.3%** (112/120) ✓ | **100%** (84/84) ✓ | **95.0%** (114/120) ✗ | 87% | 4/43 |
| gpt-5.4-mini | 93% (37/40) ✓ | 100% (27/27) ✓ | 100% ✓ | 78% | 0/13 |
| gemini-3.1-pro-preview | 98% (39/40) ✓ | 100% (29/29) ✓ | 97.5% (39/40) ✗ | 93% | 1/14 |
| claude-sonnet-4-6 | 100% ✓ | 100% (30/30) ✓ | 100% ✓ | 78% | 1/14 |
| claude-opus-4-7 | 100% ✓ | 100% (30/30) ✓ | 100% ✓ | 80% | 1/14 |
| gpt-5.5 | 100% ✓ | 100% (30/30) ✓ | 100% ✓ | 75% | 0/14 |

Supplementary: flash at thinking=high (pooled n=80): attach 96.3%, type 100%,
validity 96.3% — better, still under the validity bar, and it would be a
production config + cost change.

**Type accuracy is 100% on every model** — the five type definitions land
cleanly (260/260 typed cases across all final runs). The doc-03
description-vs-message confusion seen in draft 1 was fixed by the
"a message always has a recipient" rule.

## Bar assessment on the default model (gemini-3.5-flash)

- attach/no-attach ≥ 90%: **PASS** (93.3%)
- type accuracy ≥ 85%: **PASS** (100%)
- contract validity ≥ 98%: **FAIL** (95.0%) — blocked on one mechanical issue, below.

## Failure taxonomy (every failure across all final-text runs)

**Mechanical fence slips — 10 occurrences, 3 flavors, all type-correct content:**

1. Open fence ends `">` or `">>>>` instead of `">>>` (flash only, 7×).
2. Open fence correct but the first body line glued onto it (flash, 2× across
   all runs incl. high).
3. Close fence glued to the end of the last body line (pro-preview, 1×).

These are decoding slips at fence boundaries, not comprehension failures: in
every single case the type and title parse correctly and match the label.
Three escalating prompt drills (exact-shape bullet → chevron-count rule →
"type exactly `>`,`>`,`>` after the closing quote" + verify instruction) moved
flash from ~92% → 95% validity and then plateaued. gpt-4-class, Claude, and
GPT-5.5 models emit perfect fences; this is a flash (and rarely pro)
characteristic.

**Semantic misses — only two patterns left anywhere:**

- `ch-04-this-is-broken-no-ask` (the plan's hard case): flash attaches an
  unsolicited agent_prompt in ~half its runs (2/3 final pooled runs); mini did
  it in some earlier drafts. Opus/gpt-5.5/sonnet/pro get it right. Counted in
  flash's 93.3% attach — passes the bar even with it.
- mini occasionally under-attaches borderline snippet/agent cases (3/40 in its
  final run: ap-06, sn-03, sn-05 — answered fully in chat, no artifact).
  Stochastic; mini still ≥ bar.

**Voice (no pass bar):** chat direct-address 75–93% — remaining misses are
mostly short snippet-case chat lines ("Paste this into F2:") and the
no-request line on emp cases. "the user" in agent_prompt bodies: 0–4 per
model per run after the explicit ban + rewrite-check; flash is the worst
offender (4/43). Note the regex also flags benign "the user interface" /
"the user's avatar" end-user references.

## The decision needed (blocks locking)

Strict §2 parsing leaves the DEFAULT model at 95% validity and no prompt
change moved it further. Each remaining option is outside Phase 1's scope:

- **A (recommended): add a bounded recovery tier to the §2 parser.**
  Open fence: line starts `<<<ZERRO_ARTIFACT`, attrs parse, ≥1 trailing
  chevron; any same-line trailing text becomes the first body line. Close
  fence: also accepted at end-of-line. Everything else stays strict (line-start
  anchor, ZERRO_ magic strings, single block, unknown-type coercion,
  whole-output fallback). Measured on all final-text runs: recovers **10/10**
  invalids, all with the correct type — flash becomes **validity 100%, attach
  98.3%** (118/120; only the ch-04 flip remains), pro becomes 40/40. The §2
  collision-proofing rationale is untouched. Requires amending §2 + the
  harness parser + (in Phase 2) ArtifactParser.swift.
- **B: keep strict, accept ~95% on the default** — ~1 in 20 flash artifact
  responses degrades to chat text with visible fence junk (fail-safe, ugly).
- **C: keep strict, run flash at thinking=high** — 96.3%, still under bar;
  adds cost/latency; config change.
- **D: change the default model** — sonnet/opus/gpt-5.5 are 100% strict, but
  pricier; product/registry decision.

## Prompt iteration history

| draft | change | result (models run) |
|---|---|---|
| 1 | Initial 6-layer text per plan: BASE verbatim (minus clipboard/OUTPUT MODE ¶s), response shape w/ EXPLAIN's no-meta rule, plan's decision rule verbatim + empty-narration rule, 5 type defs (INSTRUCT ported for agent_prompt), §2 format spec, 8 few-shots | mini: 100/97/100 |
| 2 | "message has a recipient"; ban literal "the user" (end-user sense); chat-voice nudge | mini 98/100/100; flash 93/100/95 |
| 3 | borderline = must NAME a change (ch-04); one-block-multiple-items rule; always-close rule; swapped chat-only example to a this-is-broken case | mini 100/100/100; flash 93/100/93 |
| 4 | chevron-count drill ("never two or four") | flash 100/100/100 (lucky run); mini 98/100/100 |
| 5 | never promise a deliverable without attaching; "the user" alternatives list | full matrix; flash variance exposed (88–98% validity across runs) |
| 6 (final) | terminal-sequence drill (`">>>`, verify-before-body) | table above; flash validity plateaued at 95% pooled |

Key lesson: flash's fence slips are stochastic — single 40-case runs swing
±5pp on attach/validity, so flash conclusions here are pooled across runs.

## Layer structure of the final draft (per plan Phase 1)

1. Input description — production BASE verbatim through the don't-merge
   paragraph. Two removals per plan (clipboard ¶, OUTPUT MODE ¶) and one
   forced edit: the empty-narration paragraph's tail "…defined by the selected
   output mode below" → "…defined below" (modes no longer exist).
2. RESPONSE SHAPE — chat text always, second person, EXPLAIN's
   open-with-substance / no-meta-lead-in rules ported.
3. ARTIFACT DECISION — plan's rule near-verbatim + "borderline must NAME a
   change" + empty-narration handling.
4. ARTIFACT TYPES — agent_prompt ports INSTRUCT near-verbatim (second person
   to the agent, never "the user", frames→specifics, summary + ordered
   requirements + constraints); message/snippet/document/generic one-paragraph
   definitions.
5. OUTPUT FORMAT — exact §2 fence syntax, title ≤80, one-block rule,
   no-duplication rule, ~120-word chat cap with artifact.
6. EXAMPLES — 8 compact narration→response pairs: one per type (5), one
   chat-only (problem-shown-no-ask), one ambiguous-both (how-do + concrete
   change → attach), one empty-narration.

## Status

RESOLVED — Colin chose Option A (2026-06-11). The §2 recovery tier is
specified in `docs/refactor-artifact-response-plan.md`, implemented in the
harness parser, covered by `parser-tests.json`, and the prompt is locked in
`zerro-prompt-system.md` v2 (byte-mirror; the code mirrors update in Phases
3–4). See the OUTCOME section at the top for the lock-run numbers.
