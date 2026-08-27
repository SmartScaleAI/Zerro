//
//  PillCardSnapshotTests.swift
//  ZerroTests
//
//  THROWAWAY verification harness for the error-pill → card refactor. Renders
//  the failure-card states to PNGs via ImageRenderer. `.failureExpanded` is the
//  control: it's the known-good card (see the handoff screenshot), so if its
//  prose body renders here, the other failure-card snapshots are trustworthy too.
//  Delete after eyeballing.
//

import AppKit
import SwiftUI
import XCTest
@testable import Zerro

@MainActor
final class PillCardSnapshotTests: XCTestCase {

    private func renderPNG(_ view: some View, scale: CGFloat = 2) -> Data? {
        let wrapped = view.padding(40).background(Color.vfPanelBackground)
        let renderer = ImageRenderer(content: wrapped)
        renderer.scale = scale
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    func testRenderFailureCards() throws {
        let dir = URL(fileURLWithPath: "/tmp/zerro-pill-cards", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let long = RecordingFailureReason.apiKeyMissing
        let net = RecordingFailureReason.networkOffline
        let capture = RecordingFailureReason.captureInterrupted

        let cases: [(String, AnyView)] = [
            ("00-control-failureExpanded", AnyView(PillView(state: .failureExpanded(
                headline: net.headline,
                detail: "The request to the generation service failed: A server with the specified hostname could not be found. (NSURLErrorDomain, code -1003). This usually means you\u{2019}re offline or the service is temporarily unreachable \u{2014} your recording is still on disk, so Retry will run it again without re-recording."
            )))),
            ("01-error-short", AnyView(PillView(state: .error(headline: capture.headline, detail: capture.userMessage, retryable: false)))),
            ("02-error-long", AnyView(PillView(state: .error(headline: long.headline, detail: long.userMessage, retryable: false)))),
            ("03-error-retryable", AnyView(PillView(state: .error(headline: net.headline, detail: net.userMessage, retryable: true)))),
            ("04-devrecovery-named", AnyView(PillView(state: .confirmDevRecovery(
                detail: "Claude Code changed +42 \u{2212}7 in 3 files. Undo it?")))),
            ("05-devrecovery-anon", AnyView(PillView(state: .confirmDevRecovery(
                detail: "The agent changed +5 \u{2212}0 in 1 file. Undo it?")))),
            ("06-open-settings", AnyView(PillView(state: .openSettings(
                headline: long.headline,
                detail: long.detail,
                pane: .accountBilling)))),
        ]

        for (name, view) in cases {
            let png = try XCTUnwrap(renderPNG(view), "failed to render \(name)")
            try png.write(to: dir.appendingPathComponent("\(name).png"))
        }
        print("PILL_CARDS_WRITTEN \(dir.path)")
    }
}
