//
//  SelectionRect.swift
//  Zerro
//
//  Created by Colin Breeding on 5/28/26.
//
//  Structured handoff between the area-selector overlay (Phase 6)
//  and the screen-capture pipeline (Phase 7). Captured on confirm
//  and passed through `startRecording()` — Phase 6 does not consume
//  the geometry; it only threads it through so the type exists when
//  ScreenCaptureKit lands.
//
//  Coordinate convention: points, in the global AppKit screen space
//  (origin bottom-left of the primary display, y increases upward).
//  This is the same space NSScreen.frame and NSEvent.mouseLocation
//  return — keeping everything in points lets us pass the rect to
//  ScreenCaptureKit's content filters without per-call conversion.
//  Retina backing-scale concerns belong to the capture layer, not
//  to this type. The dimensions readout the user sees in the
//  overlay is also reported in points for consistency.
//

import CoreGraphics
import Foundation

struct SelectionRect: Equatable, Sendable {
    /// What the user picked. `.area` is a free-drawn region cropped out
    /// of the display; `.window` targets a single on-screen window by its
    /// CoreGraphics window ID, captured cleanly via ScreenCaptureKit's
    /// per-window filter (no overlapping windows bleed in).
    enum Target: Equatable, Sendable {
        case area
        /// `id` is the `CGWindowID` (matches `SCWindow.windowID`); `title`
        /// is a best-effort label for diagnostics only.
        case window(id: CGWindowID, title: String?)
    }

    /// The selected rectangle in points, in the global AppKit screen
    /// coordinate space. For `.window` targets this is the window's
    /// last-known frame — used for sizing and as a crop fallback if the
    /// window has closed by the time capture starts.
    let rect: CGRect

    /// `localizedName` of the screen the selection was made on. Held
    /// for forensic / multi-display purposes only — Phase 7 must not
    /// assume the screen is still attached when it consumes this.
    let screenLocalizedName: String?

    /// Discriminates area vs. window capture. Defaults to `.area` so the
    /// existing drag-to-select call sites are unchanged.
    var target: Target = .area
}
