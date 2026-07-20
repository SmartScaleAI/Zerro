//
//  ProcessingConfig.swift
//  Zerro
//
//  Created by Colin Breeding on 5/28/26.
//
//  The tunables that drive our ~$0.07-per-request cost cap. These WILL
//  be revisited — keep them here, never inlined, and keep each one's
//  rationale next to it so future tuning is informed rather than a guess.
//

import CoreGraphics
import Foundation

// `nonisolated` so this bag of pure tunables opts OUT of the project's
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` default. These are plain Sendable
// constants + pure math — nothing main-actor about them — and several are read
// from nonisolated contexts (e.g. `DevAnchorPipeline.build`'s default arguments,
// the off-main eval extraction runner). Without this, every constant becomes a
// main-actor-isolated static and those reads warn ("can not be referenced from a
// nonisolated context" — an error in the Swift 6 language mode).
nonisolated enum ProcessingConfig {

    /// Fallback/top-up cadence, in seconds. No longer the primary sampler:
    /// Phase 2 keyframes on real visual change (see the analysis tunables
    /// below), not a fixed clock. This value now serves two narrower roles —
    /// the evenly-spaced floor top-up when a static screen yields too few
    /// keyframes (via `minKeyframes`), and the legacy fixed-interval fallback
    /// if Pass-1 analysis produces no usable candidates at all. Still clamped
    /// by the frames-per-minute bounds below.
    static let sampleIntervalSeconds: Double = 2.0

    /// Longest-edge pixel cap for downsampled frames. The key insight: a
    /// frame's per-image TOKEN cost is set by the model's resolution
    /// *level*, not its pixel count. Gemini bills an image part at a fixed
    /// count per media_resolution level (we send media_resolution_high,
    /// ~1120 tokens) no matter the dimensions; OpenAI's detail:"high"
    /// normalizes to a 768px short side and bills in 512px tiles, so a
    /// 16:9 frame is ~6 tiles whether it's 1024px or 1536px wide. So 1536
    /// recovers small-text legibility (code, terminals, UI labels) that
    /// 1024 was throwing away at effectively NO added token cost. Still
    /// well below a full-Retina screenshot, so the payload BYTES stay
    /// bounded (the per-frame JPEG, not the token bill, is what this caps).
    static let maxFrameDimension: CGFloat = 1536

    /// JPEG compression quality (0.0–1.0). Failure mode to watch: JPEG
    /// artifacts smearing small/monospace text into illegibility — exactly
    /// the content the model most needs to read. 0.82 keeps that text crisp
    /// while still compressing hard enough that frame bytes stay bounded
    /// (the resolution bump above only helps if the encoder doesn't smear
    /// it back away). Quality sets payload bytes, not token cost.
    static let jpegQuality: CGFloat = 0.82

    // MARK: - Phase 2: content-driven keyframing
    //
    // Pass 1 decodes tiny thumbnails on a fast clock and measures, per
    // candidate, how much changed since the last one (motion) plus a dHash
    // fingerprint; FrameSelector turns those into the times worth encoding at
    // full res; Pass 2 encodes only the winners through the EXISTING
    // downsample (1536) / JPEG (0.82) path. All of the thresholds below are
    // STARTING POINTS to tune against the eval harness (Scripts/zerro-extract.sh
    // → eval-models.mjs) — expect to revisit them once we see frame counts and
    // cost across the baseline corpus.

    /// How often Pass 1 samples a candidate thumbnail, in seconds (0.5 = 2fps).
    /// Finer = more responsive change detection but more tiny decodes; 2fps is
    /// plenty to catch a scene settling without drowning in samples.
    static let analysisIntervalSeconds: Double = 0.5

    /// Longest-edge pixel cap for Pass-1 analysis thumbnails. Deliberately
    /// tiny: motion (mean-abs-diff) and dHash only need coarse structure, and
    /// a ~96px decode is fast and cheap, so the analysis pass stays well under
    /// the cost of decoding full frames we'd then throw away.
    static let analysisThumbnailDimension: CGFloat = 96

    /// Accumulated inter-frame change (sum of per-candidate motion since the
    /// last kept frame) needed to trigger a new keyframe. Higher = fewer,
    /// more-distinct frames; lower = denser sampling of subtle change.
    /// Tuned 0.10 → 0.05 after the first Phase 2 eval: at 0.10 the low-motion
    /// work clips never accumulated enough change and 3 of 4 fell back to the
    /// `minKeyframes` floor (over-pruned). 0.05 lets genuine section-to-section
    /// changes register while still collapsing static stretches. Re-tune
    /// against the eval harness if frame counts drift from the ~7–9/min target.
    static let changeThreshold: Double = 0.05

    /// A candidate must be ≤ this motion (vs the previous candidate) to count
    /// as "settled" and be eligible to keep. This is the scroll-settle gate:
    /// during motion it stays above the bar so nothing is emitted until the
    /// view comes to rest. Lower = stricter (waits for a stiller frame).
    static let motionStabilityThreshold: Double = 0.03

    /// Drop a keyframe whose dHash is within this Hamming distance (out of 64
    /// bits) of the last kept frame's — i.e. a near-duplicate end-state.
    /// Higher = more aggressive dedup.
    static let dedupHammingThreshold: Int = 8

    /// Hard ceiling on kept keyframes for a whole recording. Sized so the
    /// heaviest models stay near the ~$0.07 cost cap; the per-minute clamp
    /// below can lower the EFFECTIVE ceiling for short clips.
    static let maxKeyframes: Int = 28

    /// Hard ceiling on Dev-Mode ANCHOR frames — the cropped native-res
    /// `DEIXIS REFERENCE` frames `DevAnchorPipeline` appends, one per referring
    /// expression in the narration. Keyframes are bounded by `maxKeyframes`
    /// above, but the anchor count used to scale with how often the user said
    /// "this / here", so a pointy narration could push TOTAL frames
    /// (keyframes + anchors) well past the 28-frame budget (cost +
    /// vision-token blowup). 8 bounds the worst case at maxKeyframes + 8 = 36
    /// frames; when more references resolve than the cap, the
    /// highest-confidence anchors are kept (see
    /// `DevAnchorPipeline.cappedCandidates`).
    static let maxAnchorFrames: Int = 8

    /// Skip this much session pre-roll before considering keyframes — the
    /// opening moment is usually a cursor mid-click or a half-rendered surface.
    static let startOffsetSeconds: Double = 1.0

    /// Clamp bounds, retained as the Phase 2 safety net. The floor
    /// (`minKeyframes`) and the effective per-clip ceiling
    /// (`effectiveMaxKeyframes`) are DERIVED from these so a static screen
    /// can't drop to zero frames and a short/busy clip can't be flooded.
    static let minFramesPerMinute: Int = 6
    static let maxFramesPerMinute: Int = 60

    /// Floor on kept keyframes for a clip of `seconds`, derived from
    /// `minFramesPerMinute`. Lets a fully static, narrated screen still yield
    /// a few evenly-spaced frames to interleave. Never below 2 (a one-frame
    /// "multimodal" prompt is barely that) and never above the hard
    /// `maxKeyframes` ceiling.
    static func minKeyframes(forDurationSeconds seconds: Double) -> Int {
        let minutes = max(seconds, 0) / 60.0
        let floor = Int((Double(minFramesPerMinute) * minutes).rounded())
        return min(maxKeyframes, max(2, floor))
    }

    /// Effective per-clip ceiling on kept keyframes: the smaller of the
    /// absolute `maxKeyframes` cap and a per-minute ceiling from
    /// `maxFramesPerMinute`, so a 15s clip can't claim the full 28-frame
    /// budget. Never below the floor.
    static func effectiveMaxKeyframes(forDurationSeconds seconds: Double) -> Int {
        let minutes = max(seconds, 0) / 60.0
        let perMinuteCeiling = Int((Double(maxFramesPerMinute) * minutes).rounded())
        return max(minKeyframes(forDurationSeconds: seconds),
                   min(maxKeyframes, perMinuteCeiling))
    }

    // MARK: - Phase 3: on-device OCR → secret redaction

    /// Default for the "Redact detected secrets" capture preference (privacy-on
    /// by default). Controls BOTH halves of redaction together — the opaque
    /// pixel boxes over a secret AND the `[REDACTED]` masking of that secret in
    /// the OCR text attached to the payload — so the frame and its text can
    /// never disagree about what was hidden. Surfaced as a toggle in
    /// Settings → Capture (PreferencesStore.redactSecrets); this constant is the
    /// fallback when no preference is threaded (e.g. the eval extraction runner).
    static let redactSecretsDefault = true

    /// Hard ceiling on real recorded content, in seconds — the 3-minute
    /// auto-stop cap (the `.autoStopped` transition in
    /// AppState.handleElapsedUpdate). This is the SINGLE SOURCE OF TRUTH for
    /// the cap: AppState reads its auto-stop threshold from here rather than
    /// re-hardcoding it, so the recording length and frame-extraction ceiling
    /// can't drift apart. Frame extraction sources its total-frame ceiling
    /// from this too: a legitimate recording is already ≤ this, so the clamp
    /// is a no-op for real content; a malformed or sleep-inflated container
    /// duration (read back from disk as untrusted file I/O) is bounded here
    /// instead of egressing a frame set that scales with the bogus duration.
    static let maxRecordingSeconds: Double = 180

    /// Minimum real recorded content, in seconds — the manual-stop FLOOR
    /// enforced in `AppState.stopRecording`. A user who stops a recording before
    /// it reaches this many seconds has it discarded (the partial `.mov` is
    /// cancelled) with the actionable `.recordingTooShort` failure, rather than
    /// handing a near-empty clip to processing/generation. This is the SINGLE
    /// SOURCE OF TRUTH for that floor: the gate reads it here and the
    /// `.recordingTooShort` user-facing copy interpolates it, so the threshold
    /// and the message it explains can't drift apart. Unrelated to — and far
    /// below — the `maxRecordingSeconds` (180s) auto-stop CAP at the other end:
    /// one is the shortest clip we'll process, the other the longest we'll record.
    static let minRecordingSeconds: Double = 3

    /// True when a manually-stopped recording of `seconds` is below the
    /// `minRecordingSeconds` floor and must be discarded with
    /// `.recordingTooShort` rather than processed. The single decision
    /// `AppState.stopRecording` makes at manual stop, factored out as a pure
    /// function so the stop-gate is unit-testable without a live capture
    /// session. The boundary is inclusive at the floor — exactly
    /// `minRecordingSeconds` is long enough (kept), only strictly shorter is
    /// discarded — matching the `< minRecordingSeconds` gate.
    static func isBelowMinimumDuration(seconds: Double) -> Bool {
        seconds < minRecordingSeconds
    }

    /// When the recording crosses into its final stretch the pill shifts to
    /// "wrapping up" so the auto-stop at `maxRecordingSeconds` isn't a
    /// surprise (read by AppState.handleElapsedUpdate). Derived from the cap
    /// (30s before it) so the two thresholds always track together.
    static let wrappingUpSeconds: Double = maxRecordingSeconds - 30

    // MARK: - Phase 6: no-speech gate (skip Whisper on silent audio)

    /// Per-window RMS energy a normalized (−1…1) audio sample window must
    /// EXCEED for the window to count as speech (`AudioActivity.hasSpeech`).
    /// 0.01 ≈ −40 dBFS — comfortably above the noise floor of a muted mic or
    /// near-silent room tone, while well below conversational narration
    /// (typically −12…−30 dBFS, RMS ≈ 0.03–0.25). Tunable: raise it if quiet
    /// room tone is misread as speech, lower it if soft narration is missed.
    /// The gate is conservative by construction — any single window over the
    /// bar marks the clip as having speech, so it errs toward transcribing.
    static let speechRMSThreshold: Float = 0.01

    /// Window size, in samples, over which `AudioActivity.hasSpeech` computes
    /// each RMS measurement. At a 44.1 kHz export ~2048 samples ≈ 46 ms — long
    /// enough to average out a single click/pop, short enough that a brief
    /// utterance still lands inside one window. Sample-count (not seconds) so
    /// the helper stays sample-rate-agnostic and trivially unit-testable.
    static let speechWindowSamples: Int = 2048
}
