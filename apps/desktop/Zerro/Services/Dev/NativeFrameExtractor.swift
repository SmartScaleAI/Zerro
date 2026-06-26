//
//  NativeFrameExtractor.swift
//  Zerro
//
//  Dev Mode (Phase 2, Milestone 3) — native-resolution anchor frames (§11). The
//  pipeline's ~5fps keyframes are downsampled (≤~1536px) for the model + cost;
//  that's too low-res for OCR of 11–13px UI text and for a crisp crosshair
//  marker. So at an anchor moment we go back to the SOURCE video and pull the
//  frame at NATIVE (full-Retina) resolution.
//
//  On-demand, not pre-extracted: the anchor moments aren't known until the
//  deixis alignment (M4) runs against the transcript, so pre-extracting native
//  frames during processing would guess the wrong moments. Instead the source
//  `.mov` is retained for a Dev Mode recording (`ProcessedRecording.sourceVideoURL`)
//  and we extract exactly the few aligned frames here, at full res, when M5 needs
//  them — then crop a region around the cursor point (build requirement #4:
//  marked frames are CROPPED native-res regions, never full-screen Retina frames).
//

import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

enum NativeFrameExtractorError: Error {
    case generationFailed(underlying: Error)
}

enum NativeFrameExtractor {

    /// Extract the source frame nearest `seconds` at NATIVE resolution (no
    /// downsampling). Tight tolerance — the anchor moment is precise, so the
    /// marker + OCR land on the exact frame the user was pointing at.
    ///
    /// `@concurrent nonisolated` is load-bearing for off-main execution. The
    /// target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an
    /// un-annotated `static func` is `@MainActor` and runs this AVFoundation work
    /// (the synchronous preferred-track-transform load + decode) on the main
    /// thread — the Thread Performance Checker flags it and it can jank the UI in
    /// production (`DevAnchorPipeline` awaits this from the main actor). Note that
    /// `nonisolated` ALONE is NOT enough here: the target also sets
    /// `SWIFT_APPROACHABLE_CONCURRENCY = YES`, which enables
    /// `NonisolatedNonsendingByDefault` (SE-0461) — under it a plain
    /// `nonisolated async` func runs on the *caller's* executor, so a MainActor
    /// caller would keep this on main. `@concurrent` forces the body onto the
    /// global concurrent pool regardless of caller. No call-site change (callers
    /// already `await`).
    @concurrent nonisolated static func frame(atSeconds seconds: Double, from videoURL: URL) async throws -> CGImage {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Exact frame, no downscale — the whole point is full-res pixels.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = .zero // native pixel dimensions

        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        do {
            let result = try await generator.image(at: time)
            return result.image
        } catch {
            throw NativeFrameExtractorError.generationFailed(underlying: error)
        }
    }

    /// Crop a square-ish region of `cropSize` (native pixels) centered on the
    /// normalized point `(x, y)` (`[0,1]`, top-left — the cursor-track / frame
    /// space). Clamped to the image bounds, so a point near an edge yields a
    /// smaller in-bounds crop rather than going out of range. Returns the cropped
    /// image AND the point's normalized position WITHIN that crop (which is not
    /// exactly center after edge-clamping), so M5 places the marker + orders OCR
    /// against the true in-crop point. Used to bound OCR + marker + vision-token
    /// cost.
    nonisolated static func crop(
        _ image: CGImage,
        around point: (x: Double, y: Double),
        cropSize: Int
    ) -> (image: CGImage, pointInCrop: (x: Double, y: Double))? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, cropSize > 0 else { return nil }
        let pxX = point.x * Double(w)
        let pxY = point.y * Double(h)
        let half = cropSize / 2
        var minX = Int(pxX.rounded()) - half
        var minY = Int(pxY.rounded()) - half
        // Clamp the rect fully inside the image.
        minX = Swift.max(0, Swift.min(minX, w - 1))
        minY = Swift.max(0, Swift.min(minY, h - 1))
        let width = Swift.min(cropSize, w - minX)
        let height = Swift.min(cropSize, h - minY)
        guard width > 0, height > 0 else { return nil }
        let cropped = image.cropping(to: CGRect(x: minX, y: minY, width: width, height: height))
        guard let cropped else { return nil }
        let inCropX = (pxX - Double(minX)) / Double(width)
        let inCropY = (pxY - Double(minY)) / Double(height)
        // Clamp into [0,1] (a point exactly on the far edge can round to 1.0+).
        let cx = Swift.min(1, Swift.max(0, inCropX))
        let cy = Swift.min(1, Swift.max(0, inCropY))
        return (cropped, (cx, cy))
    }

    /// Encode a CGImage to JPEG bytes (for shipping a cropped native-res anchor
    /// frame to the generation call). nil on failure.
    nonisolated static func jpegData(_ image: CGImage, quality: CGFloat = 0.9) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
