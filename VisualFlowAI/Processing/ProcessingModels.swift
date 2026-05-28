//
//  ProcessingModels.swift
//  VisualFlowAI
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

import CoreMedia
import Foundation

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
}

// MARK: - ExtractedFrame

/// One downsampled JPEG pulled from the video track. `timestamp` is the
/// ACTUAL time the image generator returned, not the requested sample
/// time — the two differ because of keyframe snapping (see the pipeline's
/// tolerance handling).
struct ExtractedFrame {
    let url: URL
    let timestamp: CMTime
    let index: Int
}

// MARK: - RecordingManifest

/// Codable sidecar written to `manifest.json` in the working directory.
/// Frame filenames are stored relative (not absolute URLs) so the working
/// directory can be moved or inspected without the manifest going stale.
struct RecordingManifest: Codable {
    let audioFilename: String
    let durationSeconds: Double
    let frames: [FrameEntry]

    struct FrameEntry: Codable {
        let index: Int
        let filename: String
        let timestampSeconds: Double
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
}
