//
//  ClickResolver.swift
//  Zerro
//
//  Created by Colin Breeding on 6/6/26.
//
//  Phase 4 Part B — turns the LIVE-captured clicks (RecordedClick: normalized
//  point + time) into labeled timeline entries (ResolvedClick: time + the
//  on-screen text under the cursor). The model can't tell WHAT the user clicked
//  between sparse frames; this names it from the nearest keyframe's OCR boxes.
//
//  Pure + nonisolated (no main-actor state, no I/O) so it runs inside the
//  pipeline's existing off-main work and is trivially unit-testable. Two pieces:
//    • `resolve` — for each click, pick the keyframe nearest IN TIME, then ask
//      `label(forClickX:y:lines:)` to name it.
//    • `label(forClickX:y:lines:)` — the hit-test: a click point (normalized,
//      TOP-LEFT origin, matching the frames) against a frame's OCR line boxes
//      (Vision's normalized BOTTOM-LEFT `boundingBox`). Containing box wins
//      (tightest, when several overlap); otherwise the nearest box center within
//      a small radius; otherwise nothing.
//

import CoreGraphics
import CoreMedia
import Foundation

enum ClickResolver {

    /// Default search radius (normalized) for the "nearest box" fallback when no
    /// box directly contains the click — OCR boxes hug the glyphs, so a click a
    /// few percent of the region away from a label still resolves to it.
    static let defaultRadius: Double = 0.04

    /// Resolves clicks to `ResolvedClick`s by labeling each from the keyframe
    /// nearest in time. Input order is preserved (clicks are captured in time
    /// order). A click with no resolved label (nothing under/near the cursor, or
    /// no frames/OCR available) is DROPPED rather than emitted as a placeholder —
    /// noisy `clicked "(unlabeled)"` lines would otherwise be ≈half the clicks on
    /// a busy recording and tell the model nothing.
    ///
    /// Consequence: click-COUNTING reflects only LABELED clicks. That's
    /// acceptable today — the generation prompt doesn't answer count
    /// questions. Revisit emitting countable markers for unlabeled clicks
    /// if/when counting becomes a real feature.
    nonisolated static func resolve(clicks: [RecordedClick], frames: [ExtractedFrame]) -> [ResolvedClick] {
        guard !clicks.isEmpty else { return [] }
        return clicks.compactMap { click in
            guard let label = nearestFrame(to: click.seconds, in: frames)
                .flatMap({ self.label(forClickX: click.x, y: click.y, lines: $0.lines) }) else {
                return nil
            }
            return ResolvedClick(seconds: click.seconds, label: label)
        }
    }

    /// The keyframe whose timestamp is closest to `seconds`, or `nil` when there
    /// are no frames.
    nonisolated private static func nearestFrame(to seconds: Double, in frames: [ExtractedFrame]) -> ExtractedFrame? {
        frames.min { a, b in
            abs(CMTimeGetSeconds(a.timestamp) - seconds) < abs(CMTimeGetSeconds(b.timestamp) - seconds)
        }
    }

    /// Hit-tests a click against a frame's OCR line boxes and returns the line's
    /// text, or `nil` when nothing is under (or near) the cursor.
    ///
    /// `x`/`y` are normalized with a TOP-LEFT origin (matching the frame image);
    /// each `OCRTextLine.box` is Vision's normalized BOTTOM-LEFT `boundingBox`,
    /// so the click is flipped into that space first (`y → 1 - y`). A box that
    /// CONTAINS the point wins — the smallest such box when several overlap, so
    /// a click inside a button label beats the enclosing container. With no
    /// containing box, the nearest box center within `radius` wins. A line whose
    /// (masked) text is empty/whitespace is skipped so a hit never yields a blank
    /// label. The resolved label is run through `SecretDetector` masking before
    /// it's returned — belt-and-braces so a secret can never reach a click label
    /// even if the OCR line text arrived un-masked (the Redactor already masks
    /// per-line box text, but this makes the resolver self-defending).
    nonisolated static func label(
        forClickX x: Double,
        y: Double,
        lines: [OCRTextLine],
        radius: Double = defaultRadius
    ) -> String? {
        let point = CGPoint(x: x, y: 1.0 - y) // top-left click → bottom-left box space

        var bestContaining: OCRTextLine?
        var bestContainingArea = Double.greatestFiniteMagnitude
        var bestNear: OCRTextLine?
        var bestNearDistance = Double.greatestFiniteMagnitude

        for line in lines {
            let label = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }

            if line.box.contains(point) {
                let area = Double(line.box.width * line.box.height)
                if area < bestContainingArea {
                    bestContainingArea = area
                    bestContaining = line
                }
            } else if bestContaining == nil {
                let cx = Double(line.box.midX)
                let cy = Double(line.box.midY)
                let distance = ((Double(point.x) - cx) * (Double(point.x) - cx)
                    + (Double(point.y) - cy) * (Double(point.y) - cy)).squareRoot()
                if distance < bestNearDistance {
                    bestNearDistance = distance
                    bestNear = line
                }
            }
        }

        let resolved: String?
        if let hit = bestContaining {
            resolved = hit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let near = bestNear, bestNearDistance <= radius {
            resolved = near.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            resolved = nil
        }
        return resolved.map(redactingSecrets)
    }

    /// Masks any secret `SecretDetector` flags in a resolved label, so a click on
    /// a secret-bearing OCR line surfaces `[REDACTED]` in the timeline rather than
    /// the raw secret. Mirrors the Redactor's per-line masking so the click label
    /// and the OCR-text block stay in lock step.
    nonisolated private static func redactingSecrets(_ label: String) -> String {
        var masked = label
        for secret in SecretDetector.sensitiveSubstrings(in: label) {
            masked = masked.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        return masked
    }
}
