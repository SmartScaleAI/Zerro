//
//  VisionOCR.swift
//  Zerro
//
//  Dev Mode (Phase 2, Milestone 5) — on-device OCR of the region around a deixis
//  anchor (§7). Apple's Vision (`VNRecognizeTextRequest`, `.accurate`) reads the
//  exact visible strings near the cursor point so the dev prompt can anchor a
//  change to grep-able text ("the 'Get started' button"), and so the M6 client
//  confidence can tell a clean labeled element from empty space.
//
//  On-device, no network, no permission. Runs on the CROPPED native-res region
//  (M3) — small UI text (11–13px) only OCRs reliably at native resolution, and
//  cropping bounds the work. Best-effort: a Vision failure yields no strings, the
//  run degrades to the lower-confidence path, never crashes. Mirrors the existing
//  `Redactor` Vision setup (`.accurate`, language correction off for UI/code).
//

import Foundation
import Vision
import CoreGraphics
import os

/// One recognized string and its box. `box` is Vision-native: normalized
/// `[0,1]`, BOTTOM-LEFT origin, within the OCR'd (cropped) image.
struct OCRString: Equatable, Sendable {
    let text: String
    let box: CGRect
}

enum VisionOCR {

    /// Recognize text in `image`. When `nearTopLeft` is given (normalized
    /// `[0,1]`, TOP-LEFT — the cursor-track / frame convention), results are
    /// ordered by box-center proximity to that point, so the nearest string
    /// (most likely the pointed element's label) comes first. Capped at
    /// `maxStrings`. Best-effort → `[]` on any failure.
    static func recognize(
        _ image: CGImage,
        nearTopLeft: (x: Double, y: Double)? = nil,
        maxStrings: Int = 12
    ) -> [OCRString] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false // UI/code identifiers, not prose

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Log.dev.error("Vision OCR failed: \(error.localizedDescription, privacy: .private)")
            return []
        }
        guard let observations = request.results, !observations.isEmpty else { return [] }

        var strings: [OCRString] = []
        strings.reserveCapacity(observations.count)
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            strings.append(OCRString(text: text, box: obs.boundingBox))
        }

        if let near = nearTopLeft {
            // Vision boxes are bottom-left; the point is top-left → flip y.
            let py = 1.0 - near.y
            strings.sort {
                Self.dist($0.box, near.x, py) < Self.dist($1.box, near.x, py)
            }
        }
        return Array(strings.prefix(maxStrings))
    }

    private static func dist(_ box: CGRect, _ x: Double, _ y: Double) -> Double {
        hypot(Double(box.midX) - x, Double(box.midY) - y)
    }
}
