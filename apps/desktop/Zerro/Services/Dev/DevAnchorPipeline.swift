//
//  DevAnchorPipeline.swift
//  Zerro
//
//  Dev Mode (Phase 2, Milestone 5) — assembles the per-reference element-ID
//  input from the deixis candidates (M4) + the retained source video (M3): for
//  each referring expression, extract the native frame at the resolved moment,
//  crop a region around the cursor point, run Apple Vision OCR on it, composite a
//  crosshair marker, and compute the CLIENT confidence (dwell stillness + OCR
//  cleanliness — the client half of M6's `min(client, model)` gate).
//
//  The output feeds the ONE generation call (the marked crop + OCR + phrase per
//  reference), which returns the structured `DevAnchor` list with the model's
//  agreement. Marked frames are CROPPED native-res regions — never full-screen
//  Retina frames — bounding the payload + vision-token cost (build requirement).
//

import Foundation
import CoreGraphics

/// One reference, fully resolved on the client and ready to ship to generation.
struct ResolvedDeixisAnchor: Sendable {
    /// 0-based index of the referring expression (pairs with the model's anchor).
    let refIndex: Int
    let candidate: CandidateAnchor
    /// Nearby visible strings (nearest-first), for the prompt + client confidence.
    let ocrStrings: [String]
    /// The cropped native-res MARKED region as base64 JPEG, or nil when no point
    /// / no source video / extraction failed (the run degrades to OCR-less).
    let markedJPEGBase64: String?
    /// Client confidence `0...1` (dwell + OCR). Combined with the model's in M6.
    let clientConfidence: Double
}

enum DevAnchorPipeline {

    /// Native-pixel size of the square crop around each anchor. ~768 captures the
    /// element + enough context for OCR + the model, while bounding vision tokens.
    static let defaultCropSize = 768

    /// Build the resolved anchors. Async — extracts a native frame per reference.
    /// Best-effort per anchor: a failed extraction yields an anchor with no marked
    /// frame / OCR (still carrying the dwell point + a low client confidence).
    static func build(
        candidates: [CandidateAnchor],
        sourceVideoURL: URL?,
        cropSize: Int = defaultCropSize
    ) async -> [ResolvedDeixisAnchor] {
        var out: [ResolvedDeixisAnchor] = []
        out.reserveCapacity(candidates.count)
        for (i, c) in candidates.enumerated() {
            var ocr: [OCRString] = []
            var jpeg: String?
            if let point = c.point, let videoURL = sourceVideoURL,
               let native = try? await NativeFrameExtractor.frame(atSeconds: c.targetSeconds, from: videoURL),
               let cropped = NativeFrameExtractor.crop(native, around: (point.x, point.y), cropSize: cropSize) {
                // OCR the CLEAN crop (the marker must not pollute recognition).
                ocr = VisionOCR.recognize(cropped.image, nearTopLeft: cropped.pointInCrop)
                let marked = AnchorMarker.composite(on: cropped.image, atTopLeft: cropped.pointInCrop) ?? cropped.image
                jpeg = NativeFrameExtractor.jpegData(marked).map { $0.base64EncodedString() }
            }
            out.append(ResolvedDeixisAnchor(
                refIndex: i,
                candidate: c,
                ocrStrings: ocr.map(\.text),
                markedJPEGBase64: jpeg,
                clientConfidence: clientConfidence(candidate: c, ocr: ocr)
            ))
        }
        return out
    }

    /// The client confidence signal (§7): a click is certain; a tight dwell over a
    /// clean OCR label is high; a dwell with nothing to label is capped to
    /// medium-low; last-known / empty space is low. The MODEL agreement (from
    /// generation) is combined via `min` in M6.
    static func clientConfidence(candidate c: CandidateAnchor, ocr: [OCRString]) -> Double {
        switch c.source {
        case .click:
            return 1.0
        case .none:
            return 0.0
        case .lastKnown:
            return Swift.min(c.dwellConfidence, 0.2)
        case .dwell:
            let hasCleanLabel = (ocr.first?.text.trimmingCharacters(in: .whitespaces).count ?? 0) >= 2
            // A clean nearby label means there's something concrete to anchor to,
            // so the dwell stillness drives confidence; otherwise cap to med-low.
            return hasCleanLabel ? c.dwellConfidence : Swift.min(c.dwellConfidence, 0.45)
        }
    }
}
