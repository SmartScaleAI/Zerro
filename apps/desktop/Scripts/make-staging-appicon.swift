#!/usr/bin/env swift
//
//  make-staging-appicon.swift
//
//  Generates the `AppIcon-Staging` asset by compositing an amber "STAGING"
//  diagonal corner ribbon onto each size of the production `AppIcon`. The
//  ribbon is drawn with the `.sourceAtop` compositing op, so it paints only
//  where the base icon is opaque — clipping the banner to the icon's squircle
//  so its straight edges round off into a proper corner banner. The "STAGING"
//  text is drawn only at sizes where it is legible (>= 128px); smaller sizes
//  carry just the amber ribbon, which is enough to distinguish the build in the
//  Dock / app switcher.
//
//  Run from apps/desktop:  swift Scripts/make-staging-appicon.swift
//

import AppKit

let fm = FileManager.default
let desktopDir = URL(fileURLWithPath: fm.currentDirectoryPath)
let assets = desktopDir.appendingPathComponent("Zerro/Assets.xcassets")
let srcSet = assets.appendingPathComponent("AppIcon.appiconset")
let dstSet = assets.appendingPathComponent("AppIcon-Staging.appiconset")

// #FF9500 — Color.vfStagingAccent
let amber = NSColor(srgbRed: 1.00, green: 0.584, blue: 0.0, alpha: 1.0)
let textColor = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1.0)

let sizes = [16, 32, 64, 128, 256, 512, 1024]

try? fm.createDirectory(at: dstSet, withIntermediateDirectories: true)

func composite(size: Int) {
    let s = CGFloat(size)
    let srcURL = srcSet.appendingPathComponent("\(size)-mac.png")
    guard let base = NSImage(contentsOf: srcURL) else {
        FileHandle.standardError.write("missing \(srcURL.path)\n".data(using: .utf8)!)
        exit(1)
    }

    // Render into a bitmap rep of EXACT pixel size. `NSImage.lockFocus()` would
    // pick up the main display's backing scale (2x on Retina) and silently
    // double every output, which breaks the asset catalog's exact-pixel rule.
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    base.draw(in: rect)

    // Ribbon geometry (bottom-left origin), scaled from the 1024 design grid.
    // A diagonal band centered on the line x − y = cMid, crossing the icon's
    // bottom-right rounded corner. `.sourceAtop` clips it to the squircle so the
    // band's ends round off into a proper tucked banner. The band is built as a
    // long parallelogram (a fat diagonal strip) so it spans the full corner
    // chord — wide enough for legible text — rather than a tiny corner triangle.
    let k = s / 1024.0
    let cornerInset = 360.0 * k        // how far the band centerline sits from the canvas corner
    let cMid = s - cornerInset         // centerline: x − y = cMid
    let thickness = 200.0 * k          // band thickness (perpendicular)
    let halfT = thickness / 2
    let ext = 1200.0 * k               // half-length along the diagonal (well past the icon)
    let invSqrt2 = 1.0 / 2.0.squareRoot()

    // Corner-bisector point on the centerline = where x − y = cMid meets x + y = s.
    let c0 = NSPoint(x: (s + cMid) / 2, y: (s - cMid) / 2)
    let u = NSPoint(x: invSqrt2, y: invSqrt2)   // along the band (45°)
    let n = NSPoint(x: invSqrt2, y: -invSqrt2)  // across the band (toward the corner)

    func corner(_ su: CGFloat, _ sn: CGFloat) -> NSPoint {
        NSPoint(x: c0.x + su * ext * u.x + sn * halfT * n.x,
                y: c0.y + su * ext * u.y + sn * halfT * n.y)
    }
    let ribbon = NSBezierPath()
    ribbon.move(to: corner(1, 1))
    ribbon.line(to: corner(1, -1))
    ribbon.line(to: corner(-1, -1))
    ribbon.line(to: corner(-1, 1))
    ribbon.close()

    ctx.compositingOperation = .sourceAtop
    amber.setFill()
    ribbon.fill()

    // "STAGING" text along the band, only where legible.
    if size >= 128 {
        NSGraphicsContext.saveGraphicsState()
        ctx.compositingOperation = .sourceAtop
        ribbon.addClip() // never let glyphs spill past the ribbon onto the icon

        let fontSize = 52.0 * k
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
            .foregroundColor: textColor,
            .kern: 1.5 * k,
            .paragraphStyle: para,
        ]
        let str = NSAttributedString(string: "STAGING", attributes: attrs)
        let textSize = str.size()

        // Center on the band, rotate +45° to run along the diagonal. Nudge
        // slightly along the band toward the icon body so the visible chord
        // (the squircle clips both ends) reads symmetrically.
        let nudge = 12.0 * k
        let xform = NSAffineTransform()
        xform.translateX(by: c0.x - nudge * u.x, yBy: c0.y - nudge * u.y)
        xform.rotate(byDegrees: 45)
        xform.concat()
        str.draw(at: NSPoint(x: -textSize.width / 2, y: -textSize.height / 2))

        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    let dstURL = dstSet.appendingPathComponent("\(size)-mac.png")
    try? png.write(to: dstURL)
    print("wrote \(dstURL.lastPathComponent)")
}

for size in sizes { composite(size: size) }

// Mirror the production Contents.json (same filenames / idioms / scales).
let contents = """
{
  "images" : [
    { "filename" : "16-mac.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "32-mac.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "32-mac.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "64-mac.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "128-mac.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "256-mac.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "256-mac.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "512-mac.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "512-mac.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "1024-mac.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try? contents.write(to: dstSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
