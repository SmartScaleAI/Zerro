//
//  ProcessingPipeline.swift
//  VisualFlowAI
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
    enum Stage {
        case isolatingAudio
        case extractingFrames
        case writingManifest

        var userMessage: String {
            switch self {
            case .isolatingAudio:    return "Saving your narration\u{2026}"
            case .extractingFrames:  return "Capturing key moments\u{2026}"
            case .writingManifest:   return "Wrapping up\u{2026}"
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
        onStage: @MainActor (Stage) -> Void = { _ in }
    ) async throws -> ProcessedRecording {
        let workingDirectory = try WorkingDirectory.make()
        NSLog("[Processing] working dir: %@", workingDirectory.path)

        do {
            let asset = AVURLAsset(url: sourceURL)
            let duration = try await asset.load(.duration)

            await MainActor.run { onStage(.isolatingAudio) }
            let audioURL = try await isolateAudio(from: sourceURL, into: workingDirectory)
            NSLog("[Processing] isolated audio: %@", audioURL.lastPathComponent)

            await MainActor.run { onStage(.extractingFrames) }
            let frames = try await extractFrames(from: sourceURL, into: workingDirectory)
            NSLog(
                "[Processing] extracted %d frames (first=%@, last=%@)",
                frames.count,
                frames.first?.url.lastPathComponent ?? "—",
                frames.last?.url.lastPathComponent ?? "—"
            )

            await MainActor.run { onStage(.writingManifest) }
            try writeManifest(
                audioURL: audioURL,
                frames: frames,
                duration: duration,
                into: workingDirectory
            )
            NSLog("[Processing] manifest written")

            return ProcessedRecording(
                audioURL: audioURL,
                frames: frames,
                duration: duration,
                workingDirectory: workingDirectory
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

    /// Pulls a downsampled JPEG for each sampled time in `sourceURL`,
    /// writes them as `frame-NNN.jpg` into `workingDirectory`, and
    /// returns the ordered list. Throws only on systemic failures (no
    /// video track, every frame failed) — single keyframe misses are
    /// logged + skipped so a 3-minute recording is never doomed by one
    /// bad sample.
    func extractFrames(from sourceURL: URL, into workingDirectory: URL) async throws -> [ExtractedFrame] {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw ProcessingError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return []
        }

        let interval = Self.effectiveSampleInterval()
        // Start at `interval` (not 0) — first-frame keyframes in a
        // fresh capture are reliably present but their content is the
        // session pre-roll (cursor mid-click, half-rendered surface).
        // Stepping to `interval` lands on a settled image.
        let times: [CMTime] = stride(from: interval, through: durationSeconds, by: interval)
            .map { CMTime(seconds: $0, preferredTimescale: 600) }

        guard !times.isEmpty else {
            return []
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

        var frames: [ExtractedFrame] = []
        var index = 0

        for await item in generator.images(for: times) {
            do {
                let cgImage = try item.image
                let actualTime = try item.actualTime

                guard let downsampled = Self.downsample(
                    cgImage, maxDimension: ProcessingConfig.maxFrameDimension
                ) else {
                    NSLog("[Processing] downsample failed at index %d", index)
                    continue
                }

                let filename = String(format: "frame-%03d.jpg", index)
                let url = workingDirectory.appendingPathComponent(filename)
                guard Self.encodeJPEG(
                    downsampled, quality: ProcessingConfig.jpegQuality, to: url
                ) else {
                    NSLog("[Processing] JPEG encode failed at index %d", index)
                    continue
                }

                frames.append(ExtractedFrame(url: url, timestamp: actualTime, index: index))
                index += 1
            } catch {
                NSLog(
                    "[Processing] image generation failed at %.2fs: %@",
                    CMTimeGetSeconds(item.requestedTime),
                    String(describing: error)
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

    /// Scales `image` so its longest edge equals `maxDimension`,
    /// preserving aspect ratio. Returns the original CGImage when it's
    /// already at or below the cap. Uses CGContext directly rather
    /// than CGImageSource thumbnailing — we already have a decoded
    /// CGImage from AVAssetImageGenerator and round-tripping through
    /// the source/thumbnail API would just re-encode and re-decode.
    private static func downsample(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
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
        into workingDirectory: URL
    ) throws {
        let manifest = RecordingManifest(
            audioFilename: audioURL.lastPathComponent,
            durationSeconds: CMTimeGetSeconds(duration),
            frames: frames.map { frame in
                RecordingManifest.FrameEntry(
                    index: frame.index,
                    filename: frame.url.lastPathComponent,
                    timestampSeconds: CMTimeGetSeconds(frame.timestamp)
                )
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
    /// crashing the whole pipeline.
    private static func encodeJPEG(_ image: CGImage, quality: CGFloat, to url: URL) -> Bool {
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
