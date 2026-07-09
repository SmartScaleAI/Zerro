//
//  Redactor.swift
//  Zerro
//
//  Created by Colin Breeding on 6/6/26.
//
//  Phase 3 Part A — the single Vision pass per keyframe, used twice.
//
//  `process(_:redact:)` runs ONE on-device `VNRecognizeTextRequest` over a
//  (already-downsampled) frame and:
//    (1) REDACT — for every recognized line that `SecretDetector` flags, paints
//        an OPAQUE black box over that line's pixels (not blur — blurred text is
//        recoverable) AND masks the secret substring in the returned text. The
//        two stay in lock step so we never leak via text what we hid in pixels.
//    (2) SUPPLY — returns the (redacted) recognized text so the pipeline can
//        attach it to the frame in the payload; the model prefers it for exact
//        strings while the frame stays the source of truth for layout.
//
//  Runs entirely on-device (no network, no new entitlements) and is called from
//  inside ProcessingPipeline's EXISTING detached per-frame task, so it's
//  `nonisolated` and never touches main-actor state.
//
//  BEST-EFFORT, NEVER THROWS: a Vision failure or a frame with no text returns
//  the original image and "" — extraction must not be derailed by OCR. When
//  redaction is off, the raw image + raw text are returned unchanged.
//

import CoreGraphics
import Foundation
import Vision
import os

enum Redactor {

    /// The result of the Vision pass: the image to ENCODE (boxed if any secret
    /// was found and redaction is on), the TEXT to attach (secret substrings
    /// masked as `[REDACTED]` when redaction is on), and the per-line boxes
    /// (Phase 4 — `text` already masked, `box` = Vision's normalized bottom-left
    /// `boundingBox`) the pipeline hit-tests clicks against.
    struct Output {
        let image: CGImage
        let text: String
        let lines: [OCRTextLine]
    }

    /// Run OCR once and return the (possibly redacted) image + text. See the
    /// file header for the two uses and the best-effort contract.
    nonisolated static func process(_ image: CGImage, redact: Bool) -> Output {
        let request = VNRecognizeTextRequest()
        // `.accurate` (not `.fast`): we are reading dense small UI/code text the
        // model wants verbatim, and this runs off-main per kept frame (~tens of
        // them), so the extra latency is affordable.
        request.recognitionLevel = .accurate
        // Language correction OFF: on-screen secrets/identifiers/code are NOT
        // natural language — autocorrect would mangle the exact strings we most
        // want to preserve (and the exact strings we must match to redact).
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // OCR is best-effort — a Vision failure must not derail extraction.
            Log.processing.error("OCR failed: \(error.localizedDescription, privacy: .private)")
            // F-03: telemeter the failure — silently returning un-redacted left
            // an invisible redaction gap. Bounded metadata ONLY: the redact flag
            // (was a secret-bearing frame left un-painted?) and the coarse
            // numeric Vision error code — never the description (it can embed a
            // path), the image, or any recognized text. Hop to the main actor
            // for Analytics.capture (process() runs off-main), mirroring
            // MetricKitObserver; the chokepoint provides the consent gate
            // (I-03) + DEBUG no-op for free. Fires for both Redactor callers
            // (keyframe pipeline + DevAnchorPipeline) — both are redaction
            // paths. The empty-results branch below is deliberately NOT
            // telemetered (blank frames are expected, high-volume noise).
            let errorCode = (error as NSError).code
            Task { @MainActor in
                Analytics.capture("ocr_failed", [
                    "redact": redact,
                    "error_code": errorCode,
                ])
            }
            return Output(image: image, text: "", lines: [])
        }

        guard let observations = request.results, !observations.isEmpty else {
            return Output(image: image, text: "", lines: [])
        }

        var lines: [String] = []
        lines.reserveCapacity(observations.count)
        // Per-line boxes (Phase 4) — the FINAL (possibly masked) text + Vision's
        // normalized bottom-left bounding box, one per recognized line. The click
        // resolver hit-tests against these.
        var lineBoxes: [OCRTextLine] = []
        lineBoxes.reserveCapacity(observations.count)
        // Normalized (bottom-left origin) boxes of lines containing a secret.
        var secretBoxes: [CGRect] = []

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string

            let finalLine: String
            if redact {
                let masked = maskSecrets(in: line)
                if masked.didMask { secretBoxes.append(observation.boundingBox) }
                finalLine = masked.text
            } else {
                finalLine = line
            }

            lines.append(finalLine)
            lineBoxes.append(OCRTextLine(text: finalLine, box: observation.boundingBox))
        }

        let text = lines.joined(separator: "\n")

        // No redaction needed (off, or no secrets seen) → return the original
        // pixels untouched alongside the (raw or already-masked) text + boxes.
        guard redact, !secretBoxes.isEmpty else {
            return Output(image: image, text: text, lines: lineBoxes)
        }

        guard let boxed = paintOpaqueBoxes(over: image, normalizedBoxes: secretBoxes) else {
            // Compositing failed (context creation). The text is already masked;
            // we couldn't box the pixels. Return the masked text with the
            // original image rather than throwing — a near-impossible path
            // (CGContext alloc), logged so it's visible if it ever happens.
            Log.processing.error("OCR redaction compositing failed — \(secretBoxes.count, privacy: .public) box(es) not painted")
            return Output(image: image, text: text, lines: lineBoxes)
        }
        return Output(image: boxed, text: text, lines: lineBoxes)
    }

    // MARK: - Text masking

    /// Mask every `SecretDetector` hit in `line` as `[REDACTED]`, returning the
    /// (possibly unchanged) line and whether anything was masked. This is the
    /// TEXT half of redaction, factored out of `process` so other on-device
    /// egress paths — notably the Dev-Mode anchor OCR hint (DevAnchorPipeline) —
    /// mask their strings IDENTICALLY to the keyframe pass: same detector, same
    /// `[REDACTED]` token. The `didMask` flag tells the pixel pass which line's
    /// box to paint, keeping pixels and text in lock step.
    nonisolated static func maskSecrets(in line: String) -> (text: String, didMask: Bool) {
        let secrets = SecretDetector.sensitiveSubstrings(in: line)
        guard !secrets.isEmpty else { return (line, false) }
        var masked = line
        for secret in secrets {
            masked = masked.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        return (masked, true)
    }

    // MARK: - Compositing

    /// Draws `image` into a fresh bitmap and fills each normalized box with
    /// opaque black, returning the composited image. Vision's `boundingBox` is
    /// normalized with a BOTTOM-LEFT origin, which is exactly the default
    /// coordinate space of a CGContext bitmap (origin bottom-left, +y up) — so
    /// the box maps to pixels with NO Y-flip: `x = minX·W, y = minY·H`. Each box
    /// is padded a few pixels (OCR bounds hug the glyphs) and clamped to the
    /// image. `nonisolated` — runs in the per-frame detached task.
    nonisolated private static func paintOpaqueBoxes(over image: CGImage, normalizedBoxes: [CGRect]) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo: UInt32 = CGImageAlphaInfo.noneSkipLast.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        context.draw(image, in: bounds)
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)

        let w = CGFloat(width)
        let h = CGFloat(height)
        let pad: CGFloat = 3
        for box in normalizedBoxes {
            let pixel = CGRect(
                x: box.minX * w,
                y: box.minY * h,
                width: box.width * w,
                height: box.height * h
            ).insetBy(dx: -pad, dy: -pad).intersection(bounds)
            if !pixel.isNull, !pixel.isEmpty {
                context.fill(pixel)
            }
        }

        return context.makeImage()
    }
}
