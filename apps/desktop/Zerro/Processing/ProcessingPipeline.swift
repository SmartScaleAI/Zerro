//
//  ProcessingPipeline.swift
//  Zerro
//
//  Created by Colin Breeding on 5/28/26.
//
//  Turns a finished .mov into the Phase 8 output: one isolated M4A/AAC
//  narration track plus an ordered set of downsampled JPEG frames with a
//  manifest. Pure local work — no STT, no API calls (that's Phase 9).
//
//  Built incrementally per the Phase 8 checkpoints:
//    Step 1: audio isolation.
//    Step 2: time-based frame extraction + downsample + JPEG.
//    Step 3 (here): manifest sidecar + a top-level `process()` that
//                   orchestrates the three stages and returns a
//                   ProcessedRecording for AppState to hold.
//
//  AVFoundation note (audio export): on the macOS 26 deployment target
//  the completion-handler `exportAsynchronously` + `.status`/`.error`
//  surface is deprecated in favor of the native async `export(to:as:)`,
//  which already gives us the async/await + throwing-failure behavior we
//  want — so we call it directly rather than wrapping the old callback.
//  Preset is AppleM4A (audio-only M4A/AAC), per the Phase 8 decision.
//
//  Frame extraction (Step 2): AVAssetImageGenerator.images(for:) is the
//  modern async-streaming API. We pre-build the time list at the
//  effective sample interval (sampleIntervalSeconds, clamped by
//  min/maxFramesPerMinute), set a 500ms keyframe-snap tolerance both
//  ways, and downsample each emitted CGImage via CGContext before
//  encoding to JPEG via CGImageDestination. Individual frame failures
//  log + skip — a single bad keyframe shouldn't kill a 3-minute
//  recording — but a fully empty result throws so the failure pill
//  surfaces something visible instead of a "done" with nothing in it.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

struct ProcessingPipeline {

    /// The stages the pipeline transitions through. `onStage` fires
    /// once at the start of each, so AppState can update the pill
    /// label with real progress instead of cycling through canned
    /// strings on a timer. Labels are user-facing — friendly framings
    /// of what's actually happening (no technical jargon like
    /// "isolating," "extracting," "manifest" leaks to the pill). Phase
    /// 9 will add new stages for STT + model calls and adjust these
    /// to match the perceived flow.
    /// Stages the .processing pill cycles through during a full
    /// recording → result flow. `process()` here fires
    /// `.extractingFrames` (the umbrella for the Phase 6 concurrent
    /// isolate-audio + extract-frames block) then `.writingManifest`.
    /// `.isolatingAudio` is retained for its label/source-of-truth role
    /// but no longer fired as its own stage — audio isolation now runs
    /// concurrently under the `.extractingFrames` umbrella, so the pill
    /// shows one coherent label instead of racing between two. The last
    /// two (.transcribing, .writingPrompt) fire from
    /// AppState.runPromptGeneration AFTER process() returns — they live
    /// in this enum so the pill label has a single source of truth, even
    /// though they're driven by Phase 9 API work and not by the pipeline
    /// itself.
    enum Stage {
        case isolatingAudio
        case extractingFrames
        case writingManifest
        case transcribing
        case writingPrompt

        var userMessage: String {
            switch self {
            case .isolatingAudio:    return "Saving your narration\u{2026}"
            case .extractingFrames:  return "Capturing key moments\u{2026}"
            case .writingManifest:   return "Wrapping up\u{2026}"
            case .transcribing:      return "Transcribing your narration\u{2026}"
            case .writingPrompt:     return "Writing your prompt\u{2026}"
            }
        }
    }

    /// Top-level orchestration: creates the working directory, loads
    /// the asset's duration, isolates audio, extracts frames, writes
    /// the manifest, and returns the `ProcessedRecording` AppState
    /// stores for Phase 9. `onStage` fires at the start of each stage
    /// for the pill label. Per-stage failures surface as the typed
    /// `ProcessingError` cases — AppState maps them to the amber
    /// failure pill via `.processingFailed`.
    func process(
        sourceURL: URL,
        clicks: [RecordedClick] = [],
        redactSecrets: Bool = ProcessingConfig.redactSecretsDefault,
        onStage: @MainActor (Stage) -> Void = { _ in }
    ) async throws -> ProcessedRecording {
        let workingDirectory = try WorkingDirectory.make()
        // Full path is .private (under /var/folders/.../T/zerro-work-… which
        // contains the user's short name in the realpath).
        Log.processing.info("working dir: \(workingDirectory.path, privacy: .private)")

        do {
            let asset = AVURLAsset(url: sourceURL)
            let duration = try await asset.load(.duration)

            // A zero / non-finite duration means the container is empty
            // or corrupt (an instant stop, a header written with no
            // samples, a truncated file). Bail before wasting the audio
            // export — and before a frameless ProcessedRecording can
            // reach Phase 9. Sub-interval-short-but-nonzero recordings
            // are caught later by extractFrames (no sampled frame).
            let durationSeconds = CMTimeGetSeconds(duration)
            guard durationSeconds.isFinite, durationSeconds > 0 else {
                throw ProcessingError.emptyRecording
            }

            // Phase 6: audio isolation and frame extraction each open their own
            // `AVURLAsset` and write disjoint files (audio.m4a vs frame-NNN.jpg),
            // so they run CONCURRENTLY — wall-time drops from
            // sum(isolate, extract+OCR) to max(isolate, extract+OCR). Frame
            // extraction (now also Vision OCR + redaction per keyframe) is the
            // dominant cost, so a SINGLE umbrella stage covers the block:
            // `.extractingFrames` ("Capturing key moments…"). The two stages can
            // no longer fire in sequence, so we don't flicker the pill between
            // them — `.isolatingAudio` is retained in the enum but no longer
            // fired here. If either child throws, `try await` rethrows and the
            // sibling is cancelled on scope exit; the catch below removes the
            // partial working dir exactly as before.
            await MainActor.run { onStage(.extractingFrames) }
            async let audioURLTask = isolateAudio(from: sourceURL, into: workingDirectory)
            async let framesTask = extractFrames(from: sourceURL, into: workingDirectory, redactSecrets: redactSecrets)
            let (audioURL, frames) = try await (audioURLTask, framesTask)
            // Basename is .public — "audio.m4a" is our own constant.
            Log.processing.info("isolated audio: \(audioURL.lastPathComponent, privacy: .public)")
            // Frame basenames are `frame-NNN.jpg` (our own format), .public.
            Log.processing.info(
                "extracted \(frames.count, privacy: .public) frames (first=\(frames.first?.url.lastPathComponent ?? "—", privacy: .public), last=\(frames.last?.url.lastPathComponent ?? "—", privacy: .public))"
            )

            // Phase 4: resolve each captured click to the on-screen label under
            // the cursor, using the nearest keyframe's OCR boxes. Empty `clicks`
            // (old recording with no sidecar, or nothing clicked) → no click
            // lines; downstream is graceful.
            let resolvedClicks = ClickResolver.resolve(clicks: clicks, frames: frames)
            Log.processing.info(
                "resolved \(resolvedClicks.count, privacy: .public) click(s) from \(clicks.count, privacy: .public) captured"
            )

            // Phase 6: post-hoc no-speech check on the isolated audio. Computed
            // from the written file (not capture-time state) so re-extraction in
            // the eval harness gets the same answer. Run in a detached task to
            // keep the AVAudioFile decode + RMS scan off the main actor. A silent
            // clip (false) lets the downstream paths skip Whisper entirely; a
            // decode failure conservatively returns true (transcribe anyway).
            let hasSpeech = await Task.detached(priority: .userInitiated) {
                AudioActivity.hasSpeech(in: audioURL)
            }.value
            Log.processing.info("audio activity: hasSpeech=\(hasSpeech, privacy: .public)")

            await MainActor.run { onStage(.writingManifest) }
            try writeManifest(
                audioURL: audioURL,
                frames: frames,
                duration: duration,
                clicks: resolvedClicks,
                hasSpeech: hasSpeech,
                into: workingDirectory
            )
            Log.processing.info("manifest written")

            return ProcessedRecording(
                audioURL: audioURL,
                frames: frames,
                duration: duration,
                workingDirectory: workingDirectory,
                clicks: resolvedClicks,
                hasSpeech: hasSpeech
            )
        } catch {
            // Mid-pipeline failure: tear down the partial working dir
            // before re-throwing so AppState's .failed branch doesn't
            // have to know it exists. Launch-sweep is the safety net
            // for the residual case where this catch itself fails.
            WorkingDirectory.remove(at: workingDirectory)
            throw error
        }
    }

    /// Extracts the audio track of `sourceURL` and exports it to
    /// `audio.m4a` inside `workingDirectory`. Returns the written URL.
    func isolateAudio(from sourceURL: URL, into workingDirectory: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let outputURL = workingDirectory.appendingPathComponent("audio.m4a")

        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ProcessingError.audioExportSetupFailed
        }

        do {
            try await session.export(to: outputURL, as: .m4a)
        } catch {
            throw ProcessingError.audioExportFailed(underlying: error)
        }

        return outputURL
    }

    /// Extracts content-driven keyframes from `sourceURL`, writes them as
    /// `frame-NNN.jpg` into `workingDirectory`, and returns the ordered list.
    /// Two passes (Phase 2): Pass 1 (`analyzeCandidates`) decodes tiny
    /// thumbnails and measures change + a fingerprint per candidate; the pure
    /// `FrameSelector` picks the times worth keeping (settled, changed,
    /// non-duplicate, floored/capped); Pass 2 (the loop below) decodes only
    /// those at full resolution and reuses the existing `processFrame` /
    /// `downsample` (1536) / `encodeJPEG` (0.82) path. The manifest schema,
    /// `frame-NNN.jpg` naming, chronological order, and per-frame `actualTime`
    /// timestamps are all unchanged — downstream is untouched.
    ///
    /// Throws on systemic failures (no video track, a too-short/empty
    /// recording that yields no times, every frame failed) — single keyframe
    /// misses are logged + skipped so a 3-minute recording is never doomed by
    /// one bad sample. Never returns an empty array: zero frames is always a
    /// thrown failure so the downstream API step can't run on nothing.
    func extractFrames(from sourceURL: URL, into workingDirectory: URL, redactSecrets: Bool = ProcessingConfig.redactSecretsDefault) async throws -> [ExtractedFrame] {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw ProcessingError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw ProcessingError.emptyRecording
        }

        // Clamp the analyzed/encoded span to the recording cap. The asset
        // is read back from disk (untrusted file I/O): a malformed or
        // sleep-inflated container could report a duration far beyond the
        // 3-minute cap, and the work scales linearly with it. A legitimate
        // recording is already ≤ the cap (auto-stop at 180s), so `min` is a
        // no-op for real content and only bites the abnormal over-cap case.
        let cappedDurationSeconds = min(durationSeconds, ProcessingConfig.maxRecordingSeconds)

        // --- Pass 1: cheap analysis ------------------------------------------
        // Decode tiny thumbnails on a fast clock and measure, per candidate,
        // how much changed since the last one (motion) plus a dHash. This is
        // the signal the pure FrameSelector keyframes on; the full-res decode
        // (Pass 2) only touches the winners.
        let candidates = await analyzeCandidates(
            asset: asset,
            cappedDurationSeconds: cappedDurationSeconds
        )

        // --- Selector: pick the winners --------------------------------------
        let params = SelectionParams(
            startOffsetSeconds: ProcessingConfig.startOffsetSeconds,
            changeThreshold: ProcessingConfig.changeThreshold,
            stabilityThreshold: ProcessingConfig.motionStabilityThreshold,
            dedupHamming: ProcessingConfig.dedupHammingThreshold,
            maxKeyframes: ProcessingConfig.effectiveMaxKeyframes(forDurationSeconds: cappedDurationSeconds),
            minKeyframes: ProcessingConfig.minKeyframes(forDurationSeconds: cappedDurationSeconds)
        )
        let selectedIndices = FrameSelector.select(candidates, config: params)

        // Map the chosen candidate indices back to their (settled) actualTime
        // seconds — those are the times Pass 2 encodes at full resolution.
        let byIndex = Dictionary(uniqueKeysWithValues: candidates.map { ($0.index, $0.timestampSeconds) })
        var selectedSeconds = selectedIndices.compactMap { byIndex[$0] }.sorted()

        if selectedSeconds.isEmpty {
            // Pass 1 produced no usable candidates (e.g. every tiny decode
            // failed). Fall back to the legacy fixed-interval cadence so a
            // valid recording still yields frames rather than throwing here —
            // a genuinely unreadable asset still fails below when every
            // full-res decode also fails. The absolute frame ceiling guards
            // against an over-cap duration slipping past the clamp above.
            let interval = Self.effectiveSampleInterval()
            let maxFrames = ProcessingConfig.maxFramesPerMinute * 3
            selectedSeconds = Array(
                stride(from: interval, through: cappedDurationSeconds, by: interval).prefix(maxFrames)
            )
            Log.processing.error("frame analysis produced no candidates — falling back to fixed-interval sampling")
        }

        let times = selectedSeconds.map { CMTime(seconds: $0, preferredTimescale: 600) }

        guard !times.isEmpty else {
            // Duration is positive but too short to yield even one candidate
            // or fallback time. Too short to analyze — fail rather than land
            // on a zero-frame "success".
            throw ProcessingError.emptyRecording
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 500ms tolerance both ways. Tighter than the default
        // (positiveInfinity) so we don't drift seconds off the
        // requested sample; loose enough to land on the nearest
        // keyframe rather than forcing an inter-frame decode.
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        // Resolve the config clamps once, here on the main actor, so the
        // detached per-frame work captures plain Sendable scalars and
        // never reaches back into main-isolated config. `redactSecrets` is
        // threaded in the same way (resolved at the call site from the
        // capture preference) rather than read inside the nonisolated task.
        let maxDimension = ProcessingConfig.maxFrameDimension
        let jpegQuality = ProcessingConfig.jpegQuality
        let redact = redactSecrets

        var frames: [ExtractedFrame] = []
        var index = 0

        for await item in generator.images(for: times) {
            do {
                let cgImage = try item.image
                let actualTime = try item.actualTime

                // The decode above runs on AVFoundation's own threads, but
                // because extractFrames is main-actor-isolated (the
                // project's SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor) this
                // `for await` resumes on main. Hand the synchronous pixel
                // work — a CGContext draw of a possibly-4K CGImage plus the
                // JPEG encode, ~90–150 times — to a detached task so it
                // genuinely runs off the main thread. Marking processFrame
                // `nonisolated` alone would NOT suffice: a synchronous
                // nonisolated function runs on whoever calls it (here,
                // main). The Task.detached is what moves it off (M1's
                // lesson). The CGImage is created and consumed inside the
                // closure, so nothing non-Sendable outlives the hop.
                let frame = await Task.detached(priority: .userInitiated) {
                    Self.processFrame(
                        cgImage,
                        index: index,
                        actualTime: actualTime,
                        maxDimension: maxDimension,
                        jpegQuality: jpegQuality,
                        redact: redact,
                        into: workingDirectory
                    )
                }.value
                guard let frame else { continue }

                frames.append(frame)
                index += 1
            } catch {
                // Timestamp is .public (a position into our own buffer,
                // not user content). Error description is .private (may
                // embed paths or AVFoundation internal state). Pre-format
                // the Double rather than threading OSLogFloatFormatting
                // through the interpolation — terser and SDK-stable.
                let ts = String(format: "%.2fs", CMTimeGetSeconds(item.requestedTime))
                Log.processing.error(
                    "image generation failed at \(ts, privacy: .public): \(error.localizedDescription, privacy: .private)"
                )
            }
        }

        // Systemic failure: every requested time failed. The recording
        // is unusable for the downstream prompt-generation step (Phase
        // 9), so route through .failed rather than landing on .done
        // with zero frames.
        if frames.isEmpty {
            throw ProcessingError.frameEncodingFailed(index: 0)
        }

        return frames
    }

    // MARK: - Helpers

    /// Resolves the configured `sampleIntervalSeconds` against the
    /// min/maxFramesPerMinute clamps. At today's 2.0s default this is
    /// a no-op; wired so future tuning (or experimental change-detection
    /// sampling) can't blow past the cost cap or starve the model.
    private static func effectiveSampleInterval() -> Double {
        let computedFPM = 60.0 / ProcessingConfig.sampleIntervalSeconds
        if computedFPM > Double(ProcessingConfig.maxFramesPerMinute) {
            return 60.0 / Double(ProcessingConfig.maxFramesPerMinute)
        }
        if computedFPM < Double(ProcessingConfig.minFramesPerMinute) {
            return 60.0 / Double(ProcessingConfig.minFramesPerMinute)
        }
        return ProcessingConfig.sampleIntervalSeconds
    }

    /// Pass 1: decode tiny thumbnails every `analysisIntervalSeconds` across
    /// the capped duration and turn each into a `Candidate` (motion vs the
    /// previous thumbnail + a dHash fingerprint). Returns them in time order;
    /// returns `[]` (not a throw) if the analysis decode produces nothing —
    /// the caller falls back to fixed-interval sampling so a one-off thumbnail
    /// failure doesn't doom an otherwise-valid recording.
    ///
    /// Uses a SEPARATE generator with `maximumSize` ≈
    /// `analysisThumbnailDimension` so candidates decode tiny and fast, and a
    /// tolerance smaller than the analysis interval so requested times don't
    /// all snap onto the same keyframe. The per-thumbnail pixel work (two
    /// small grayscale draws) is handed to a detached task to keep it off the
    /// main actor, exactly as the full-res path does.
    private func analyzeCandidates(
        asset: AVURLAsset,
        cappedDurationSeconds: Double
    ) async -> [Candidate] {
        let analysisGenerator = AVAssetImageGenerator(asset: asset)
        analysisGenerator.appliesPreferredTrackTransform = true
        let dimension = ProcessingConfig.analysisThumbnailDimension
        analysisGenerator.maximumSize = CGSize(width: dimension, height: dimension)
        // Tolerance < analysisInterval (0.2s vs 0.5s) so requested times stay
        // distinct rather than collapsing onto a shared keyframe.
        let tolerance = CMTime(seconds: 0.2, preferredTimescale: 600)
        analysisGenerator.requestedTimeToleranceBefore = tolerance
        analysisGenerator.requestedTimeToleranceAfter = tolerance

        let analysisTimes: [CMTime] = stride(
            from: 0.0, through: cappedDurationSeconds, by: ProcessingConfig.analysisIntervalSeconds
        ).map { CMTime(seconds: $0, preferredTimescale: 600) }
        guard !analysisTimes.isEmpty else { return [] }

        // Square grayscale side used for the motion buffer — resolved once so
        // the detached work captures a plain Int, not main-isolated config.
        let madSide = max(1, Int(dimension))

        var candidates: [Candidate] = []
        var previousGray: [UInt8]? = nil
        var index = 0

        for await item in analysisGenerator.images(for: analysisTimes) {
            guard let cgImage = try? item.image, let actualTime = try? item.actualTime else {
                // A single thumbnail miss is non-fatal — skip it. The motion of
                // the NEXT successful candidate is then measured against the
                // last good one, which is the intended "since the previous
                // kept sample" semantics anyway.
                continue
            }

            let analysis = await Task.detached(priority: .userInitiated) { () -> (gray: [UInt8], hash: UInt64)? in
                guard let gray = Self.grayscaleBuffer(cgImage, width: madSide, height: madSide) else {
                    return nil
                }
                return (gray, Self.dHash(cgImage))
            }.value
            guard let analysis else { continue }

            // First candidate has no predecessor → motion 0 (matches Candidate's
            // contract and seeds the selector's settled-frame search).
            let motion = previousGray.map { Self.meanAbsoluteDifference(analysis.gray, $0) } ?? 0.0
            candidates.append(
                Candidate(
                    index: index,
                    timestampSeconds: CMTimeGetSeconds(actualTime),
                    motion: motion,
                    hash: analysis.hash
                )
            )
            previousGray = analysis.gray
            index += 1
        }

        return candidates
    }

    /// Draws `image` into a fixed `width`×`height` 8-bit grayscale buffer and
    /// returns the raw bytes (row-major, `bytesPerRow == width`). The aspect
    /// ratio is intentionally NOT preserved — every candidate is stretched into
    /// the same box, so the distortion is identical frame-to-frame and the
    /// motion diff / dHash stay comparable. `nonisolated` so it runs inside the
    /// analysis pass's detached task. Returns `nil` if the context can't be
    /// created. Low interpolation: the target is tiny and we want speed, not
    /// fidelity.
    nonisolated private static func grayscaleBuffer(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var data = [UInt8](repeating: 0, count: width * height)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }

    /// Normalized mean-absolute-difference of two equal-length grayscale
    /// buffers, in 0…1 (sum of |a−b| over bytes, divided by count×255). The
    /// per-candidate "motion" signal. `nonisolated` — pure arithmetic.
    nonisolated private static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum = 0
        for i in a.indices {
            sum += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(sum) / (Double(a.count) * 255.0)
    }

    /// 64-bit difference hash: draw `image` into a 9×8 grayscale grid and set
    /// one bit per row per adjacent-pixel pair where the left pixel is brighter
    /// than the right (8 comparisons × 8 rows = 64 bits). A robust perceptual
    /// fingerprint for the selector's near-duplicate dedup. `nonisolated` so it
    /// runs in the analysis pass's detached task. Returns 0 if the tiny decode
    /// fails — two failed hashes then read as identical (Hamming 0), which the
    /// selector treats as a near-duplicate; acceptable for a degenerate frame.
    nonisolated private static func dHash(_ image: CGImage) -> UInt64 {
        guard let buffer = grayscaleBuffer(image, width: 9, height: 8) else { return 0 }
        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for row in 0..<8 {
            let rowStart = row * 9
            for col in 0..<8 {
                if buffer[rowStart + col] > buffer[rowStart + col + 1] {
                    hash |= (1 << bit)
                }
                bit += 1
            }
        }
        return hash
    }

    /// Downsamples one decoded frame and writes it to disk as
    /// `frame-NNN.jpg`, returning the `ExtractedFrame` on success or `nil`
    /// (after logging) when the downsample or JPEG encode fails — the same
    /// log-and-skip behavior the loop had inline. `nonisolated` so it can
    /// run inside `extractFrames`' detached task without the project's
    /// MainActor-default isolation bouncing the pixel work back to main;
    /// it touches only its (Sendable) arguments and the already-nonisolated
    /// `downsample`/`encodeJPEG`/`Log.processing`, so no main-actor state
    /// is reached. The config clamps are passed in (not read from
    /// `ProcessingConfig`) to keep that read on the main actor at the call
    /// site.
    nonisolated private static func processFrame(
        _ image: CGImage,
        index: Int,
        actualTime: CMTime,
        maxDimension: CGFloat,
        jpegQuality: CGFloat,
        redact: Bool,
        into workingDirectory: URL
    ) -> ExtractedFrame? {
        guard let downsampled = downsample(image, maxDimension: maxDimension) else {
            Log.processing.error("downsample failed at index \(index, privacy: .public)")
            return nil
        }

        // Phase 3: one on-device Vision OCR pass over the (downsampled) frame,
        // AFTER downsample and BEFORE encode. It returns the image to encode
        // (with opaque boxes painted over any detected secret when `redact`) and
        // the recognized text (secrets masked as [REDACTED]) to attach to the
        // frame. Best-effort — never throws; a no-text/failed frame yields "".
        // We encode the RETURNED image so the redaction lands in the JPEG bytes
        // that actually egress.
        let recognized = Redactor.process(downsampled, redact: redact)

        let filename = String(format: "frame-%03d.jpg", index)
        let url = workingDirectory.appendingPathComponent(filename)
        guard encodeJPEG(recognized.image, quality: jpegQuality, to: url) else {
            Log.processing.error("JPEG encode failed at index \(index, privacy: .public)")
            return nil
        }

        // Empty OCR text is carried as nil (not "") so the manifest omits the
        // key and the interleaver emits no `on-screen text:` block for it.
        let ocrText = recognized.text.isEmpty ? nil : recognized.text
        // Phase 4: the OCR line boxes ride along in-memory so the click resolver
        // can name a click from this frame's on-screen text (never persisted).
        return ExtractedFrame(url: url, timestamp: actualTime, index: index, ocrText: ocrText, lines: recognized.lines)
    }

    /// Scales `image` so its longest edge equals `maxDimension`,
    /// preserving aspect ratio. Returns the original CGImage when it's
    /// already at or below the cap. Uses CGContext directly rather
    /// than CGImageSource thumbnailing — we already have a decoded
    /// CGImage from AVAssetImageGenerator and round-tripping through
    /// the source/thumbnail API would just re-encode and re-decode.
    /// `nonisolated` so the per-frame draw + makeImage runs off the main
    /// actor inside `processFrame`'s detached task.
    nonisolated private static func downsample(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let originalSize = CGSize(width: image.width, height: image.height)
        let longestEdge = max(originalSize.width, originalSize.height)
        if longestEdge <= maxDimension { return image }

        let scale = maxDimension / longestEdge
        let targetWidth = max(1, Int((originalSize.width * scale).rounded()))
        let targetHeight = max(1, Int((originalSize.height * scale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // BGRA layout with the alpha byte ignored — frame captures
        // have no meaningful alpha (the screen is opaque), and dropping
        // it keeps the JPEG encoder on its hot path.
        let bitmapInfo: UInt32 = CGImageAlphaInfo.noneSkipLast.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    /// Writes the `manifest.json` sidecar that Phase 9 will consume.
    /// Frame filenames are stored as basenames (not absolute URLs) so
    /// the working directory can be moved or inspected without the
    /// manifest going stale. Pretty-printed + sorted keys keep diffs
    /// readable when inspecting captured recordings during dev.
    func writeManifest(
        audioURL: URL,
        frames: [ExtractedFrame],
        duration: CMTime,
        clicks: [ResolvedClick] = [],
        hasSpeech: Bool = true,
        into workingDirectory: URL
    ) throws {
        let manifest = RecordingManifest(
            audioFilename: audioURL.lastPathComponent,
            durationSeconds: CMTimeGetSeconds(duration),
            hasSpeech: hasSpeech,
            frames: frames.map { frame in
                RecordingManifest.FrameEntry(
                    index: frame.index,
                    filename: frame.url.lastPathComponent,
                    timestampSeconds: CMTimeGetSeconds(frame.timestamp),
                    ocrText: frame.ocrText
                )
            },
            // Phase 4: omit the key entirely when there are no clicks so older
            // readers + clickless recordings stay clean (nil → no `clicks` field).
            clicks: clicks.isEmpty ? nil : clicks.map {
                RecordingManifest.ClickEntry(timestampSeconds: $0.seconds, label: $0.label)
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let url = workingDirectory.appendingPathComponent("manifest.json")
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ProcessingError.manifestWriteFailed(underlying: error)
        }
    }

    /// Writes `image` to `url` as JPEG at the given quality (0…1).
    /// Returns false if either the destination couldn't be created or
    /// finalize failed; the caller logs + skips on false rather than
    /// crashing the whole pipeline. `nonisolated` so the encode runs off
    /// the main actor inside `processFrame`'s detached task.
    nonisolated private static func encodeJPEG(_ image: CGImage, quality: CGFloat, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return false }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
