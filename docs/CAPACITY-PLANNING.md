# Capacity planning — API rate limits & concurrency

**What this answers:** can our current provider keys handle a worst-case 3-minute
recording, and how many people can record *at the same time* before requests
start failing? Written for the Managed path (the server `generate` function
calls the provider with our org keys; BYOK users spend their own keys and don't
count here).

**Figures dated:** June 2026. **Source of truth is always the live console**, not
this doc — Anthropic `platform.claude.com/settings/limits`, Google AI Studio
`aistudio.google.com/rate-limit`, OpenAI `platform.openai.com/settings/.../limits`.
Provider docs render their numeric tables via JavaScript, so several figures
below are corroborated from secondary sources and flagged where confidence is
lower. Re-check the console before making a tier-upgrade decision.

---

## TL;DR

- **A single recording never fails.** Even the heaviest 3-minute, 28-frame
  recording is a few-percent slice of a *per-minute* budget, sent as one
  request. There is no single-recording risk on any provider.
- **The only variable that matters is recordings-per-minute across all users.**
  Rate limits are per-minute and org-wide, so concurrency — not recording size —
  is what to plan around.
- **Current (Tier 1) concurrent ceilings before any 429:** ~18–37/min on the
  default Gemini Flash path, ~7–8/min if users are on Claude Sonnet, ~4/min on
  the OpenAI mini model. Whisper transcription (every recording) caps the whole
  system at ~50/min.
- **Above those ceilings users wait a few seconds, they don't hard-fail** —
  because the back-end now backs off and respects `Retry-After` (see
  "What's already in place").
- **First scaling lever:** Anthropic → Tier 2 ($40). **First daily ceiling to
  watch:** Gemini's ~1,000–1,500 requests/day on Tier 1.

---

## 1. The worst-case recording payload

A recording is hard-capped at **28 frames** (`ProcessingConfig.maxKeyframes`). A
3-minute clip computes to a 180-frame per-minute ceiling but clamps to 28 — the
cap is sized to keep cost near ~$0.07/recording. Frames are downsampled to
1536px long edge at JPEG 0.82. (The server fuse `MAX_FRAMES = 200` is far above
what the app can emit; only a forged client could approach it.)

A heavy 3-minute recording's input payload:

| Component | Tokens (approx.) |
|---|---|
| 28 frames (images) | provider-dependent — see below |
| System prompt (`prompt.ts`, ~16 KB) | ~4,500 |
| OCR text (≤ 8 KB/frame cap; realistic heavy) | ~15,000 |
| Transcript (~3 min speech) | ~600 |
| Clicks | ~2,000 |
| **Non-frame subtotal** | **~22,000** |

Output is ~1,000 tokens regardless (the typed-artifact response).

### Image tokenization differs sharply by provider

This is what drives the per-recording total. Each provider counts a 1536px frame
differently:

| Provider / model | Tokens per frame | **Total input per recording** |
|---|---|---|
| **Gemini 3.5 Flash** *(recommended default)* | ~1,120 (flat, resolution-budgeted) | **~53,000** |
| **Anthropic Sonnet 4.6** | ~1,568 (downscaled to the per-image cap) | **~66,000** |
| **OpenAI gpt-5.5** | ~2,300 (32px-patch) | **~87,000** |
| **Anthropic Opus 4.7** | ~3,025 (high-res tier, up to 4,784) | **~107,000** |
| **OpenAI gpt-5.4-mini** | ~3,700 (patch × 1.6 mini multiplier) | **~126,000** |

All of these fit comfortably inside every model's context window (200K–1M+), so
**no recording is ever rejected for size.**

---

## 2. Provider rate limits (current tier)

Limits are per-minute and enforced at the **organization / project** level
(shared across all keys in that org/project). Three dimensions matter: requests
per minute (RPM), input/total tokens per minute (ITPM/TPM), and output tokens
per minute (OTPM). A 429 fires if you cross **any one**.

### Anthropic — Tier 1 (from our console)

| Model class | RPM | ITPM | OTPM |
|---|---|---|---|
| Claude Sonnet 4.6 | 1,000 | 500,000 | 80,000 |
| Claude Opus 4.7 | 1,000 | 500,000 | 80,000 |

> **Confidence note / discrepancy:** these are the numbers shown in *our*
> console at Tier 1. Third-party guides list a much lower generic Tier 1 (50 RPM
> / 30K ITPM) and put 500K–800K ITPM at Tiers 3–4. Our visible Tier 1 is already
> at/above their Tier 3, so do **not** trust the blog tables for our higher-tier
> numbers — read the console. Sonnet 4.x is one pooled bucket across 4.6/4.5;
> Opus is one pooled bucket across 4.x. Only **uncached** input counts toward
> ITPM, and `max_tokens` does **not** reserve OTPM.

Tier thresholds: Tier 1 = $5, Tier 2 = $40, Tier 3 = $200, Tier 4 = $400
(cumulative credit purchases; advancement is automatic and immediate). Published
scaling at higher tiers is roughly Tier 3 ≈ 2,000 RPM / 800K ITPM / 160K OTPM
(Sonnet) and Tier 4 ≈ 2M ITPM / 400K OTPM — **verify in console.**

### Google Gemini — Tier 1 (paid, billing enabled)

| Model | RPM | TPM | RPD |
|---|---|---|---|
| Gemini 3.5 Flash *(default)* | ~300 | 1,000,000–2,000,000 | ~1,000–1,500 |
| Gemini 3.1 Pro (preview) | ~150 | ~1,000,000 | ⚠️ possibly ~250 |

> **Confidence note:** Gemini stopped publishing per-model numbers in static
> docs; these are from the AI Studio dashboard via secondary sources. **Avoid
> relying on Gemini 3.1 Pro for volume** — preview models can be pinned to a
> ~250/day cap even on Tier 1. Limits are **per Google Cloud project**; a
> separate project gets its own quota pool but shares the billing account's tier
> and monthly spend cap. Tier 1 is instant on enabling billing; Tier 2 at $100
> cumulative spend + 3 days (≈ 2,000 RPM / 4M TPM / 10,000 RPD for Flash).

### OpenAI — Tier 1

| Surface | Limit |
|---|---|
| Chat/vision (gpt-5.x) | ~500,000 TPM |
| **Whisper STT (`whisper-1`)** | **50 RPM** (separate pool; runs on every recording) |

> **Confidence note:** OpenAI's public comms emphasize TPM over RPM for the
> gpt-5.x line; Whisper per-tier RPM (50 → 100 → 500 → 1,000 → 2,000+ across
> Tiers 1–5) is secondary-sourced. Whisper file cap is 25 MB (our ≤3-min audio
> is well under). Limits are per **organization**; a separate *project*
> sub-partitions the same org pool rather than adding capacity (only a separate
> org is additive). Tier thresholds: $5 / $50 / $100 / $250 / $1,000 cumulative,
> with minimum account-age gates.

---

## 3. Single recording — always safe

One worst-case recording against the current Tier 1 budgets:

| Path | Per-recording input | Share of one minute's budget |
|---|---|---|
| Gemini Flash | ~53K | ~3–5% of 1–2M TPM |
| Anthropic Sonnet | ~66K | ~13% of 500K ITPM |
| OpenAI gpt-5.5 | ~87K | ~17% of 500K TPM |
| OpenAI gpt-5.4-mini | ~126K | ~25% of 500K TPM |

Output (~1K) is a rounding error against the 80K OTPM budget. **Conclusion: a
single recording, even maxed out, cannot fail on rate limits.** It also fits
every context window with large margin.

---

## 4. Concurrent recordings — the real ceiling

How many recordings can land in the **same rolling minute** before the next one
429s. This is `per-minute budget ÷ per-recording tokens`. (A single user can't
self-stampede — the back-end enforces a per-identity concurrency cap of 1 — so
this load comes from *different* users.)

| Path (chat model the user picked) | Binding limit @ Tier 1 | **Concurrent recordings/min** |
|---|---|---|
| **Gemini Flash** *(default)* | TPM | **~18–37** (＋ ~1,000–1,500/day cap) |
| **Anthropic Sonnet** | 500K ITPM | **~7–8** |
| **OpenAI gpt-5.5** | 500K TPM | **~5–6** |
| **OpenAI gpt-5.4-mini** | 500K TPM | **~4** |
| **Whisper STT** (every recording) | 50 RPM | **~50** (universal cap, all paths) |

**Reading this:** every recording makes one Whisper call regardless of chat
model, so 50/min is a ceiling sitting *above* every chat ceiling at Tier 1 — the
chat provider binds first. The effective per-path ceiling is the smaller of its
chat row and Whisper's 50. So today:

- **Default (Gemini Flash) path: ~18–37 simultaneous recordings/minute** before
  any failure.
- **Claude Sonnet path: ~7–8/minute** — the tightest realistic path.
- Below these numbers: **zero failures.** Above them: the overflow **queues and
  retries with backoff**, so users see a short wait, not an error.

### Worst case, spelled out

If a crowd all fire max-frame 3-minute recordings inside the same minute: on the
default Gemini path the ~18th–37th is the first to wait; if everyone happened to
be on Sonnet, the ~8th. For a launch and early growth that is ample headroom —
it implies low-thousands of recordings/day and bursts of dozens of truly
simultaneous submissions.

---

## 5. What's already in place

- **Burst backoff:** the eval harness and the production retry path use
  exponential backoff with jitter that honors `Retry-After`, instead of an
  immediate re-fire (which previously turned one throttle into a cascade of
  429s). See `apps/desktop/Scripts/eval-models.mjs` and
  `supabase/functions/generate/providers/anthropic.ts`.
- **Per-user concurrency cap = 1:** one identity can't have two generations in
  flight, so a single user can't stampede the org limit.
- **Dev/prod key separation:** test bursts run on dedicated `*_API_KEY_DEV` keys
  in separate, rate-capped projects/workspaces and can't degrade live users
  (see DEPLOY-RUNBOOK § 3a).

---

## 6. Scaling levers & upgrade triggers

In order of impact:

1. **Anthropic → Tier 2 ($40 cumulative).** Sonnet/Opus is the tightest path;
   upgrading multiplies its ITPM/OTPM. Do this first if Managed Claude usage
   grows. **Trigger:** sustained bursts approaching ~7–8 Sonnet recordings/min,
   or any acceleration-limit 429s.
2. **Watch Gemini's daily cap.** Flash Tier 1 is ~1,000–1,500 requests/**day** —
   the first wall the default path hits at volume. **Trigger:** approaching
   ~1,000 Managed recordings/day. Tier 2 (≈ 10,000 RPD) clears it.
3. **Prompt-cache the system prompt** (~4,500 tokens/recording). Modest ITPM
   relief (frames dominate and can't be cached) but a real per-call cost cut;
   cached reads don't count toward Anthropic ITPM.
4. **Keep the queue/backoff** so any ceiling degrades into a wait, not a failure.
5. **OpenAI Whisper headroom:** 50/min at Tier 1 is comfortably above the chat
   ceilings, but it's the shared per-recording tax — revisit when total
   recordings approach ~50/min sustained (Tier 3 raises it to ~500/min).

### A note on the acceleration limit

Anthropic (and, less explicitly, the others) throttle a *sharp ramp from idle*
even when you're under the steady ceilings. Organic users arrive gradually and
won't trip this; synchronized test bursts do (this is what caused the
2026-06-12 incident). The dev-key separation and backoff already address it.
When intentionally raising load, ramp over hours, not all at once.

---

## 7. Open items to verify in-console

- Exact Anthropic Tier 2–4 RPM/ITPM/OTPM (third-party tables conflict with our
  visibly-higher Tier 1 — trust the console).
- Whether Gemini 3.1 Pro Preview carries a ~250/day Tier 1 cap (avoid it for
  volume until confirmed).
- OpenAI Whisper RPM at Tiers 2–4 (secondary-sourced).
- Re-confirm all figures at the next provider pricing/limit change — this doc is
  a point-in-time snapshot (June 2026).

---

## Sources

- Anthropic: [rate limits](https://platform.claude.com/docs/en/api/rate-limits),
  [vision/image tokens](https://platform.claude.com/docs/en/build-with-claude/vision)
- Gemini: [rate limits](https://ai.google.dev/gemini-api/docs/rate-limits),
  [token counting](https://ai.google.dev/gemini-api/docs/tokens),
  [media resolution](https://ai.google.dev/gemini-api/docs/media-resolution)
- OpenAI: [rate limits](https://developers.openai.com/api/docs/guides/rate-limits),
  [vision tokens](https://developers.openai.com/api/docs/guides/images-vision),
  [speech-to-text](https://developers.openai.com/api/docs/guides/speech-to-text/)
- Our live consoles (authoritative): Anthropic
  `platform.claude.com/settings/limits`, Google AI Studio
  `aistudio.google.com/rate-limit`, OpenAI
  `platform.openai.com/settings/organization/limits`
