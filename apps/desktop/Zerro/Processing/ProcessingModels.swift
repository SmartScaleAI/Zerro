//
//  ProcessingModels.swift
//  Zerro
//
//  Created by Colin Breeding on 5/28/26.
//
//  Phase 8 output data model. The processing pipeline turns a finished
//  .mov into one isolated audio file plus an ordered set of downsampled
//  JPEG frames, and hands both off as a `ProcessedRecording`. Phase 9
//  will consume that struct (STT + multimodal prompt generation); Phase
//  8 only produces it and lands on the existing placeholder result.
//
//  `manifest.json` (RecordingManifest) is the source of truth Phase 9
//  reads; the zero-padded frame filenames are for human inspection.
//

import CoreGraphics
import CoreMedia
import Foundation

// MARK: - RecordedClick

/// Phase 4 — one mouse click captured LIVE during recording (clicks are not in
/// the `.mov`, so they're carried out-of-band). `x`/`y` are NORMALIZED to
/// `[0,1]` within the CAPTURED region, with a TOP-LEFT origin so they match the
/// frame images (and Vision's OCR boxes after a y-flip). `seconds` is the
/// click's offset from session start (the same clock the timeline tags use).
///
/// `Codable` so the eval loop can persist a `<stem>.clicks.json` sidecar beside
/// the source `.mov` and replay the exact clicks on re-extraction; `Sendable`
/// because RecordingSession appends to an array read at finalize across the
/// main-actor boundary.
struct RecordedClick: Codable, Sendable, Equatable {
    let seconds: Double
    let x: Double
    let y: Double
}

// MARK: - ResolvedClick

/// Phase 4 — a `RecordedClick` after its on-screen label has been resolved from
/// the nearest keyframe's OCR line boxes (the pipeline's job). Carries only what
/// the timeline needs: the click's `seconds` and the resolved `label` (the
/// on-screen element text under the cursor). Clicks that resolve to no label are
/// dropped by the resolver, so every `ResolvedClick` is labeled. The raw
/// coordinates are dropped here — they've done their job.
struct ResolvedClick: Sendable, Equatable {
    let seconds: Double
    let label: String
}

// MARK: - OCRTextLine

/// Phase 4 — one OCR-recognized line with its bounding box, surfaced by the
/// Redactor so the click resolver can hit-test a click against the on-screen
/// text. `box` is Vision's `boundingBox`: normalized `[0,1]`, BOTTOM-LEFT origin
/// (the resolver flips a top-left click into this space). Carried in-memory only
/// (never persisted) — `Sendable` so it rides out of the detached per-frame task
/// on `ExtractedFrame`.
struct OCRTextLine: Sendable, Equatable {
    let text: String
    let box: CGRect
}

// MARK: - ProcessedRecording

/// The result of locally processing a finished recording. `frames` is
/// temporally ordered (ascending `index`/`timestamp`). `workingDirectory`
/// is the single unit of cleanup — deleting it removes the audio, every
/// frame, and the manifest in one shot.
struct ProcessedRecording {
    let audioURL: URL
    let frames: [ExtractedFrame]
    let duration: CMTime
    let workingDirectory: URL
    /// Phase 4 — clicks captured during recording, each already resolved to the
    /// on-screen label under the cursor (from the nearest keyframe's OCR). Empty
    /// for an old recording with no clicks sidecar, or one where nothing was
    /// clicked. The interleaver merges these into the timeline as
    /// `[M:SS] clicked "<label>"` lines; the manifest mirrors them so the eval
    /// harness can rebuild the same timeline.
    let clicks: [ResolvedClick]

    /// Phase 6 — whether the isolated audio carries any detectable speech
    /// (`AudioActivity.hasSpeech`), computed post-hoc from `audio.m4a`. `false`
    /// means a silent/screen-only clip: the generation paths skip the Whisper
    /// call entirely (BYOK locally; Managed by sending `has_speech:false` so the
    /// server short-circuits STT) and compose from frames + OCR + clicks alone.
    /// Mirrored into the manifest so the eval harness makes the same skip.
    let hasSpeech: Bool

    /// Stable per-recording idempotency key (M1). Minted ONCE here, when the
    /// processed recording is produced, and carried unchanged across every
    /// generation retry of THIS recording — `retryFailedPrompt` re-runs against
    /// the same `ProcessedRecording` value, and a value copy preserves this
    /// `let` rather than re-minting it. The Managed proxy sends it as the
    /// `Idempotency-Key` header so a charged-but-dropped `/generate` response is
    /// replayed on retry instead of charging a second credit. A genuinely new
    /// recording yields a new `ProcessedRecording`, hence a new key.
    ///
    /// Defaults to a fresh UUID for every NEW recording. An explicit initializer
    /// (below) accepts it so a recording RECONSTRUCTED from disk for a
    /// Continue-after-pay resume (`reconstruct(workingDirectory:idempotencyKey:)`)
    /// can carry the ORIGINAL key — the proxy then replays the charged-but-blocked
    /// `/generate` instead of charging a second credit. The default keeps every
    /// existing call site (pipeline, tests) compiling unchanged.
    let idempotencyKey: String

    /// Explicit memberwise init with `idempotencyKey` defaulting to a fresh UUID,
    /// so all existing construction sites keep compiling while a reconstruction
    /// can inject the original recording's key (M5 resume-after-purchase).
    init(
        audioURL: URL,
        frames: [ExtractedFrame],
        duration: CMTime,
        workingDirectory: URL,
        clicks: [ResolvedClick],
        hasSpeech: Bool,
        idempotencyKey: String = UUID().uuidString
    ) {
        self.audioURL = audioURL
        self.frames = frames
        self.duration = duration
        self.workingDirectory = workingDirectory
        self.clicks = clicks
        self.hasSpeech = hasSpeech
        self.idempotencyKey = idempotencyKey
    }
}

// MARK: - ExtractedFrame

/// One downsampled JPEG pulled from the video track. `timestamp` is the
/// ACTUAL time the image generator returned, not the requested sample
/// time — the two differ because of keyframe snapping (see the pipeline's
/// tolerance handling).
///
/// `Sendable` (all fields already are) so the off-main per-frame work in
/// `ProcessingPipeline.processFrame` can construct it and hand it back to
/// the main actor. Conforming also opts the struct out of the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` inference, so its
/// memberwise init isn't main-isolated and can run in the detached task.
struct ExtractedFrame: Sendable {
    let url: URL
    let timestamp: CMTime
    let index: Int
    /// Phase 3 — the on-device-OCR text recognized in this frame, with any
    /// detected secrets masked as `[REDACTED]`. `nil`/empty when OCR found no
    /// text or failed (best-effort). The interleaver attaches it after the
    /// frame's image block so the model can prefer it for exact strings.
    let ocrText: String?

    /// Phase 4 — the frame's OCR line boxes (text + normalized bottom-left box),
    /// carried IN-MEMORY only (never written to the manifest). The pipeline uses
    /// them to resolve a click's on-screen label by hit-testing the click point
    /// against this frame's lines. Empty when OCR found nothing or for the many
    /// construction sites that don't supply it.
    let lines: [OCRTextLine]

    /// Explicit init with `ocrText`/`lines` defaults so the (many) existing
    /// 3-argument construction sites — tests, fixtures — keep compiling while
    /// the pipeline's Pass-2 path supplies the recognized text + boxes.
    init(url: URL, timestamp: CMTime, index: Int, ocrText: String? = nil, lines: [OCRTextLine] = []) {
        self.url = url
        self.timestamp = timestamp
        self.index = index
        self.ocrText = ocrText
        self.lines = lines
    }
}

// MARK: - RecordingManifest

/// Codable sidecar written to `manifest.json` in the working directory.
/// Frame filenames are stored relative (not absolute URLs) so the working
/// directory can be moved or inspected without the manifest going stale.
struct RecordingManifest: Codable {
    let audioFilename: String
    let durationSeconds: Double
    /// Phase 6 — whether the isolated audio carried detectable speech
    /// (`AudioActivity.hasSpeech`). Mirrored from `ProcessedRecording.hasSpeech`
    /// so the eval harness can make the SAME no-speech skip the live paths do
    /// (skip Whisper when `false`). Additive: older manifests/readers that lack
    /// the key default to "has speech" (transcribe), the safe direction.
    let hasSpeech: Bool
    let frames: [FrameEntry]
    /// Phase 4 — the recording's resolved clicks, mirrored into the LOCAL
    /// manifest so the eval harness can rebuild the exact `[M:SS] clicked
    /// "<label>"` timeline the live payload sends. Omitted from the JSON when
    /// empty (older manifests/readers stay valid; a clickless recording carries
    /// no key).
    let clicks: [ClickEntry]?

    struct FrameEntry: Codable {
        let index: Int
        let filename: String
        let timestampSeconds: Double
        /// Phase 3 — the frame's redacted on-device-OCR text. Omitted from the
        /// JSON when absent (`nil`) so older manifests/readers stay valid and a
        /// no-text frame doesn't carry an empty key. Lives in the LOCAL manifest
        /// so the eval harness can mirror the exact text the live payload sends.
        let ocrText: String?
    }

    /// Phase 4 — one resolved click in the manifest. `timestampSeconds` matches
    /// the `FrameEntry` naming; `label` is the on-screen element under the cursor
    /// (always present — unlabeled clicks are dropped by the resolver).
    struct ClickEntry: Codable {
        let timestampSeconds: Double
        let label: String
    }
}

// MARK: - RecordingManifest reading (M5 — resume after purchase)

/// Failure decoding a `manifest.json` back into a `RecordingManifest` /
/// `ProcessedRecording`. Surfaced by the reconstruction path so a held
/// recording with a missing or corrupt manifest is treated as orphaned (the
/// pending record is cleared) rather than crashing the restore.
enum ManifestReadError: Error {
    /// No `manifest.json` in the working directory (deleted/never written).
    case manifestMissing
    /// The `manifest.json` bytes wouldn't decode into a `RecordingManifest`.
    case manifestUndecodable(underlying: Error)
}

extension RecordingManifest {
    /// Decodes the `manifest.json` sidecar from `workingDirectory`. The inverse
    /// of `ProcessingPipeline.writeManifest`. Throws `ManifestReadError` when the
    /// file is absent or won't decode.
    static func read(fromWorkingDirectory workingDirectory: URL) throws -> RecordingManifest {
        let url = workingDirectory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else {
            throw ManifestReadError.manifestMissing
        }
        do {
            return try JSONDecoder().decode(RecordingManifest.self, from: data)
        } catch {
            throw ManifestReadError.manifestUndecodable(underlying: error)
        }
    }
}

extension ProcessedRecording {
    /// Rebuilds a `ProcessedRecording` from a working directory's `manifest.json`
    /// — the on-disk artifacts (audio, frames) are untouched by the original
    /// generation failure, so reading the manifest reconstitutes everything the
    /// generation needs. Used by the resume-after-purchase path to re-run a
    /// held recording's generation after the user pays.
    ///
    /// `idempotencyKey` is injected so the resumed generation reuses the ORIGINAL
    /// recording's key (the proxy replays a charged-but-blocked response instead
    /// of double-charging). The in-memory-only `ExtractedFrame.lines` aren't
    /// rebuilt — clicks are already resolved in the manifest, so generation never
    /// needs them. Throws `ManifestReadError` on a missing/corrupt manifest.
    static func reconstruct(
        workingDirectory: URL,
        idempotencyKey: String
    ) throws -> ProcessedRecording {
        let manifest = try RecordingManifest.read(fromWorkingDirectory: workingDirectory)
        let timescale: CMTimeScale = 600
        let frames = manifest.frames
            .sorted { $0.index < $1.index }
            .map { entry in
                ExtractedFrame(
                    url: workingDirectory.appendingPathComponent(entry.filename),
                    timestamp: CMTime(seconds: entry.timestampSeconds, preferredTimescale: timescale),
                    index: entry.index,
                    ocrText: entry.ocrText
                )
            }
        let clicks = (manifest.clicks ?? []).map {
            ResolvedClick(seconds: $0.timestampSeconds, label: $0.label)
        }
        return ProcessedRecording(
            audioURL: workingDirectory.appendingPathComponent(manifest.audioFilename),
            frames: frames,
            duration: CMTime(seconds: manifest.durationSeconds, preferredTimescale: timescale),
            workingDirectory: workingDirectory,
            clicks: clicks,
            hasSpeech: manifest.hasSpeech,
            idempotencyKey: idempotencyKey
        )
    }
}

// MARK: - ProcessingError

/// Failures the pipeline can surface. AppState maps these to the existing
/// amber failure pill (see `RecordingFailureReason.processingFailed`) —
/// they are never swallowed.
enum ProcessingError: Error {
    case workingDirectoryCreationFailed(underlying: Error)
    case audioExportSetupFailed
    case audioExportFailed(underlying: Error?)
    case noVideoTrack
    case frameEncodingFailed(index: Int)
    case manifestWriteFailed(underlying: Error)
    /// The recording is empty or unusably short — duration is zero or
    /// non-finite (corrupt/unreadable container, an instant stop, a
    /// truncated file), or too brief to yield even one sampled frame.
    /// Thrown instead of producing a frameless `ProcessedRecording`, so
    /// the failure surfaces on the pill rather than handing zero frames
    /// plus near-empty audio to the Phase 9 API step. AppState maps this
    /// to the dedicated `.recordingTooShort` copy (not the generic
    /// `.processingFailed`).
    case emptyRecording
}
