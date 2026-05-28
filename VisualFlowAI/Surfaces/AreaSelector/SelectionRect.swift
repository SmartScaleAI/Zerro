//
//  SelectionRect.swift
//  VisualFlowAI
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
    /// The selected rectangle in points, in the global AppKit screen
    /// coordinate space.
    let rect: CGRect

    /// `localizedName` of the screen the selection was made on. Held
    /// for forensic / multi-display purposes only — Phase 7 must not
    /// assume the screen is still attached when it consumes this.
    let screenLocalizedName: String?
}
