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
    static func frame(atSeconds seconds: Double, from videoURL: URL) async throws -> CGImage {
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
    /// smaller in-bounds crop rather than going out of range. Used by M5 to bound
    /// the OCR + marker region and the vision-token cost.
    static func crop(_ image: CGImage, around point: (x: Double, y: Double), cropSize: Int) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, cropSize > 0 else { return nil }
        let cx = Int((point.x * Double(w)).rounded())
        let cy = Int((point.y * Double(h)).rounded())
        let half = cropSize / 2
        var minX = cx - half
        var minY = cy - half
        // Clamp the rect fully inside the image.
        minX = Swift.max(0, Swift.min(minX, w - 1))
        minY = Swift.max(0, Swift.min(minY, h - 1))
        let width = Swift.min(cropSize, w - minX)
        let height = Swift.min(cropSize, h - minY)
        guard width > 0, height > 0 else { return nil }
        return image.cropping(to: CGRect(x: minX, y: minY, width: width, height: height))
    }

    /// Encode a CGImage to JPEG bytes (for shipping a cropped native-res anchor
    /// frame to the generation call). nil on failure.
    static func jpegData(_ image: CGImage, quality: CGFloat = 0.9) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
