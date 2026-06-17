//
//  AnchorMarker.swift
//  Zerro
//
//  Dev Mode (Phase 2, Milestone 5) — composite a crosshair MARKER on the cropped
//  native-res anchor frame at the cursor point (§7). The marked frame is what the
//  generation model sees: "the element under THIS crosshair is the one the user
//  pointed at," disambiguating it from everything else on screen. Paired with the
//  nearby OCR strings, it lets the model return a confident labeled anchor.
//

import Foundation
import CoreGraphics

enum AnchorMarker {

    /// Draw a crosshair (ring + cross) centered on the normalized `point`
    /// (`[0,1]`, TOP-LEFT) over `image`, returning a new image the same size. nil
    /// only on a context-allocation failure (then the caller ships the unmarked
    /// crop + relies on OCR proximity). A high-contrast magenta that almost never
    /// occurs in UI, so the model can't confuse the marker with content.
    static func composite(on image: CGImage, atTopLeft point: (x: Double, y: Double)) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // CGContext is bottom-left; the frame + point are top-left. Draw the
        // image upright, then flip the point's y to match.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let cx = point.x * Double(w)
        let cy = (1.0 - point.y) * Double(h) // top-left → bottom-left
        let radius = Double(min(w, h)) * 0.06 // ~6% of the shorter edge
        let line = max(2.0, Double(min(w, h)) * 0.006)

        let magenta = CGColor(red: 1, green: 0, blue: 0.85, alpha: 0.95)
        let halo = CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)

        // Dark halo under the marker so it reads on a light OR dark UI.
        ctx.setStrokeColor(halo)
        ctx.setLineWidth(line + 2)
        strokeMarker(ctx, cx: cx, cy: cy, radius: radius)
        ctx.setStrokeColor(magenta)
        ctx.setLineWidth(line)
        strokeMarker(ctx, cx: cx, cy: cy, radius: radius)

        return ctx.makeImage()
    }

    private static func strokeMarker(_ ctx: CGContext, cx: Double, cy: Double, radius: Double) {
        ctx.strokeEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
        let gap = radius * 0.35, arm = radius * 1.6
        ctx.move(to: CGPoint(x: cx - arm, y: cy)); ctx.addLine(to: CGPoint(x: cx - gap, y: cy))
        ctx.move(to: CGPoint(x: cx + gap, y: cy)); ctx.addLine(to: CGPoint(x: cx + arm, y: cy))
        ctx.move(to: CGPoint(x: cx, y: cy - arm)); ctx.addLine(to: CGPoint(x: cx, y: cy - gap))
        ctx.move(to: CGPoint(x: cx, y: cy + gap)); ctx.addLine(to: CGPoint(x: cx, y: cy + arm))
        ctx.strokePath()
    }
}
