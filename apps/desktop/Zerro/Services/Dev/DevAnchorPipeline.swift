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
    /// `nonisolated` so it can back `build`'s default argument: default-argument
    /// expressions are evaluated in a nonisolated context, so a main-actor-isolated
    /// static here would warn (an error in the Swift 6 language mode).
    nonisolated static let defaultCropSize = 768

    /// Build the resolved anchors. Async — extracts a native frame per reference.
    /// Best-effort per anchor: a failed extraction yields an anchor with no marked
    /// frame / OCR (still carrying the dwell point + a low client confidence).
    ///
    /// `redactSecrets` mirrors the keyframe contract (F-01): when ON, the crop
    /// pixels AND the OCR hint strings are passed through the SAME `Redactor` /
    /// `SecretDetector` pass the keyframes use, in lock step, BEFORE the marker is
    /// composited and the crop is encoded — so the anchor path never egresses a
    /// raw secret the user asked to redact. OFF is the pre-fix behavior unchanged.
    static func build(
        candidates: [CandidateAnchor],
        sourceVideoURL: URL?,
        cropSize: Int = defaultCropSize,
        redactSecrets: Bool = ProcessingConfig.redactSecretsDefault
    ) async -> [ResolvedDeixisAnchor] {
        // F-05: bound the anchor count BEFORE the expensive per-reference work
        // (native frame decode + crop + OCR + a payload frame each) so total
        // frames — keyframes (≤ maxKeyframes) + anchors — stay bounded no
        // matter how many referring expressions the narration produced.
        let selected = cappedCandidates(candidates)
        var out: [ResolvedDeixisAnchor] = []
        out.reserveCapacity(selected.count)
        for (i, c) in selected {
            var ocr: [OCRString] = []
            var jpeg: String?
            if let point = c.point, let videoURL = sourceVideoURL,
               let native = try? await NativeFrameExtractor.frame(atSeconds: c.targetSeconds, from: videoURL) {
                // F-08: everything downstream of the full-res decode — the
                // crop, the Vision OCR pass, redaction, marker compositing and
                // the JPEG encode — runs inside a per-iteration
                // `autoreleasepool` so each anchor's decoded-pixel
                // intermediates are released before the NEXT anchor decodes.
                // Without it the autoreleased CG/Vision objects for EVERY
                // anchor pool until the enclosing scope drains, spiking peak
                // memory at 5K native resolution. (`native` itself is scoped
                // to this `if` body, so ARC frees the full-res frame per
                // iteration; the decode can't join the pool because it's an
                // `await`.) Behavior-identical — memory lifetime only.
                (ocr, jpeg) = autoreleasepool { () -> ([OCRString], String?) in
                    guard let cropped = NativeFrameExtractor.crop(
                        native, around: (point.x, point.y), cropSize: cropSize
                    ) else { return ([], nil) }
                    // OCR the CLEAN crop (the marker must not pollute recognition).
                    let recognized = VisionOCR.recognize(cropped.image, nearTopLeft: cropped.pointInCrop)
                    // F-01: redact the crop pixels + OCR hint in lock step BEFORE the
                    // marker is composited / the crop is encoded (no-op when OFF).
                    let safe = redactCrop(cropped.image, ocr: recognized, redact: redactSecrets)
                    let marked = AnchorMarker.composite(on: safe.image, atTopLeft: cropped.pointInCrop) ?? safe.image
                    return (safe.ocr, NativeFrameExtractor.jpegData(marked).map { $0.base64EncodedString() })
                }
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

    /// F-05 — the candidates worth resolving, capped at `maxAnchors`, each
    /// paired with its ORIGINAL 0-based referring-expression index (the
    /// `refIndex` the model's anchors pair back on, so dropping a candidate
    /// never renumbers the survivors). At or under the cap this is the
    /// identity. Over it, the highest-confidence candidates win, ranked by the
    /// pre-extraction client confidence (`clientConfidence` with no OCR — the
    /// best estimate available before any frame is decoded: click > dwell >
    /// last-known > none), tie-broken by raw dwell stillness and then by
    /// transcript order. Survivors are returned in transcript order. Pure, so
    /// the cap is unit-testable without a source video.
    nonisolated static func cappedCandidates(
        _ candidates: [CandidateAnchor],
        maxAnchors: Int = ProcessingConfig.maxAnchorFrames
    ) -> [(refIndex: Int, candidate: CandidateAnchor)] {
        let indexed = candidates.enumerated().map { (refIndex: $0.offset, candidate: $0.element) }
        guard indexed.count > maxAnchors else { return indexed }
        return indexed
            .sorted { a, b in
                let ca = clientConfidence(candidate: a.candidate, ocr: [])
                let cb = clientConfidence(candidate: b.candidate, ocr: [])
                if ca != cb { return ca > cb }
                if a.candidate.dwellConfidence != b.candidate.dwellConfidence {
                    return a.candidate.dwellConfidence > b.candidate.dwellConfidence
                }
                return a.refIndex < b.refIndex
            }
            .prefix(Swift.max(0, maxAnchors))
            .sorted { $0.refIndex < $1.refIndex }
    }

    /// F-01 — apply the keyframe redaction contract to a SINGLE anchor crop:
    ///   • PIXELS: run the crop through the SAME `Redactor` box pass the keyframes
    ///     use, painting opaque boxes over EVERY detected secret line in the crop
    ///     (full-crop coverage, not just the strings we attach). The crop is small
    ///     (~768²), so the extra on-device Vision pass is negligible.
    ///   • TEXT: mask each (proximity-ordered) OCR hint string with the SAME
    ///     `SecretDetector`, so a secret blacked out in the crop is also
    ///     `[REDACTED]` in the text the model sees — pixels and text in lock step.
    /// `redact == false` returns the inputs unchanged (OFF is byte-for-byte the
    /// pre-fix path). Pure + Vision-only, so it's unit-testable on a synthesized
    /// crop with no source video (see DevAnchorRedactionTests).
    nonisolated static func redactCrop(
        _ image: CGImage,
        ocr: [OCRString],
        redact: Bool
    ) -> (image: CGImage, ocr: [OCRString]) {
        guard redact else { return (image, ocr) }
        let boxed = Redactor.process(image, redact: true).image
        let masked = ocr.map { OCRString(text: Redactor.maskSecrets(in: $0.text).text, box: $0.box) }
        return (boxed, masked)
    }

    /// The client confidence signal (§7): a click is certain; a tight dwell over a
    /// clean OCR label is high; a dwell with nothing to label is capped to
    /// medium-low; last-known / empty space is low. The MODEL agreement (from
    /// generation) is combined via `min` in M6. `nonisolated` — pure math over
    /// its arguments, and the F-05 cap ranks candidates with it from a
    /// nonisolated context.
    nonisolated static func clientConfidence(candidate c: CandidateAnchor, ocr: [OCRString]) -> Double {
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
