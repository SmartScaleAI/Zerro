//
//  ProcessingConfig.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/28/26.
//
//  The tunables that drive our ~$0.07-per-request cost cap. These WILL
//  be revisited — keep them here, never inlined, and keep each one's
//  rationale next to it so future tuning is informed rather than a guess.
//

import CoreGraphics
import Foundation

enum ProcessingConfig {

    /// Baseline seconds between sampled frames. Time-based sampling is
    /// the Phase 8 approach; real change-detection is deferred (see the
    /// frames-per-minute clamp below, which scaffolds that future work's
    /// safety net). Start at 2.0 — one frame every 2 seconds.
    static let sampleIntervalSeconds: Double = 2.0

    /// Longest-edge pixel cap for downsampled frames. Tradeoff: small UI
    /// text must survive legibly so the model can read it, but we are NOT
    /// shipping full Retina screenshots to a paid API. 1024 keeps typical
    /// code/UI text readable while bounding the per-frame payload.
    static let maxFrameDimension: CGFloat = 1024

    /// JPEG compression quality (0.0–1.0). Failure mode to watch: JPEG
    /// artifacts smearing small text into illegibility. 0.6 is the
    /// starting balance of payload size vs. text fidelity.
    static let jpegQuality: CGFloat = 0.6

    /// Clamp bounds so future change-detection sampling can neither drop
    /// a static screen to zero frames (min) nor let a busy/scrolling page
    /// explode the frame budget and the cost cap (max). Wired now even
    /// though pure time-based sampling at 2.0s (= 30 frames/min) sits
    /// comfortably inside these and won't usually trigger the clamp.
    static let minFramesPerMinute: Int = 6
    static let maxFramesPerMinute: Int = 60
}
