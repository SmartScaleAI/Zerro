//
//  EvalExtractionRunnerTests.swift
//  ZerroTests
//
//  Phase 0 — the `zerro-extract` runner.
//
//  This is NOT a pass/fail unit test. It's a thin XCTest harness that drives
//  the REAL `ProcessingPipeline.process(sourceURL:)` on a `.mov` so the eval
//  corpus can re-extract a working directory (frames + audio + manifest.json)
//  through production code — never a reimplementation. Upcoming phases change
//  the frames themselves (sampling, resolution, OCR); evaluating those changes
//  means re-running THIS pipeline on a captured `source.mov`, then diffing the
//  result against the originally-captured working dir.
//
//  Why an XCTest and not a standalone command-line target: the app project is
//  a `PBXFileSystemSynchronizedRootGroup` (Xcode 16+), so a new command-line
//  target would mean hand-fabricating a native target + product + build phases
//  in project.pbxproj. Dropping a file into `ZerroTests/` instead makes it an
//  automatic target member with zero project surgery, and `@testable import`
//  gives us the internal `ProcessingPipeline` directly. The pipeline is the
//  single source of truth — this file only orchestrates I/O around it.
//
//  USAGE (via the wrapper):
//      Scripts/zerro-extract.sh <input.mov> --out <dir>
//
//  …which sets the two env vars below and runs only this test. You can also
//  invoke it directly — note the `TEST_RUNNER_` prefix, which is how xcodebuild
//  forwards env into the hosted test process (it strips the prefix before the
//  runner sees it):
//      TEST_RUNNER_ZERRO_EXTRACT_IN=/path/source.mov \
//      TEST_RUNNER_ZERRO_EXTRACT_OUT=/tmp/reextract \
//        xcodebuild test -project Zerro.xcodeproj -scheme Zerro \
//        -only-testing:ZerroTests/EvalExtractionRunnerTests/testExtract
//
//  When the env vars are absent (a normal `xcodebuild test` run / CI), the
//  test SKIPS — it never fails the suite and never touches the network.
//

import AVFoundation
import XCTest
@testable import Zerro

final class EvalExtractionRunnerTests: XCTestCase {

    /// Runs the production extraction pipeline on `$ZERRO_EXTRACT_IN` and copies
    /// the resulting working directory's contents into `$ZERRO_EXTRACT_OUT`.
    /// `@MainActor` because `ProcessingPipeline.process` is main-actor isolated
    /// under the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    @MainActor
    func testExtract() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let inPath = env["ZERRO_EXTRACT_IN"], let outPath = env["ZERRO_EXTRACT_OUT"] else {
            throw XCTSkip(
                "zerro-extract runner: set ZERRO_EXTRACT_IN and ZERRO_EXTRACT_OUT to run "
                + "(normal test runs skip this).")
        }

        let fm = FileManager.default
        let inputURL = URL(fileURLWithPath: inPath)
        let outURL = URL(fileURLWithPath: outPath, isDirectory: true)

        XCTAssertTrue(
            fm.fileExists(atPath: inputURL.path),
            "input .mov not found at \(inputURL.path)")

        // Phase 4: replay the clicks sidecar (`<stem>.clicks.json`) if present, so
        // re-extraction rebuilds the same `[M:SS] clicked "…"` lines the live run
        // produced. Absent (old baseline .mov, or a clickless recording) → zero
        // click lines, which the pipeline handles gracefully.
        let clicksSidecarURL = inputURL.deletingPathExtension().appendingPathExtension("clicks.json")
        var replayClicks: [RecordedClick] = []
        if let data = try? Data(contentsOf: clicksSidecarURL),
           let decoded = try? JSONDecoder().decode([RecordedClick].self, from: data) {
            replayClicks = decoded
            print("zerro-extract: replaying \(replayClicks.count) click(s) from \(clicksSidecarURL.lastPathComponent)")
        }

        // --- run the REAL pipeline (with a launch-sweep retry) ---------------
        // The pipeline writes its working dir under the system temp dir with a
        // `zerro-work-` prefix. The test HOST is the full Zerro.app, and its
        // one-shot launch `WorkingDirectory.sweep()` deletes every `zerro-*`
        // tmp entry — which can race with and delete THIS extraction's working
        // dir mid-flight (surfacing as frameEncodingFailed or manifestWriteFailed
        // depending on when the sweep lands). The real app never hits this: it
        // creates working dirs during a recording, long after launch sweep has
        // fired. Here we just retry — the sweep is one-shot and early, so any
        // attempt that starts after it completes succeeds. A few attempts is
        // ample margin (each attempt fully re-extracts in well under a second).
        var processed: ProcessedRecording!
        var lastError: Error?
        for attempt in 1...4 {
            do {
                processed = try await ProcessingPipeline().process(sourceURL: inputURL, clicks: replayClicks)
                if attempt > 1 {
                    print("zerro-extract: succeeded on attempt \(attempt) "
                        + "(earlier attempt lost its working dir to the host app's launch sweep)")
                }
                break
            } catch {
                lastError = error
            }
        }
        guard let processed else {
            XCTFail("zerro-extract: pipeline never completed across retries — \(String(describing: lastError))")
            throw lastError ?? ProcessingError.frameEncodingFailed(index: 0)
        }
        let workingDirectory = processed.workingDirectory

        // --- copy the working dir's contents into --out ----------------------
        // Fresh out dir each run so a re-extract never mixes with a stale one.
        if fm.fileExists(atPath: outURL.path) {
            try fm.removeItem(at: outURL)
        }
        try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
        let entries = try fm.contentsOfDirectory(
            at: workingDirectory, includingPropertiesForKeys: nil)
        for entry in entries {
            try fm.copyItem(at: entry, to: outURL.appendingPathComponent(entry.lastPathComponent))
        }

        // --- clean up the tmp working dir (this runner owns its lifecycle) ---
        // Direct removeItem (not WorkingDirectory.remove) so the eval-retention
        // flag, if ever set in a DEBUG run of the suite, can't strand it.
        try? fm.removeItem(at: workingDirectory)

        // --- report ----------------------------------------------------------
        let frameCount = processed.frames.count
        let firstTs = processed.frames.first.map { CMTimeGetSeconds($0.timestamp) } ?? 0
        let lastTs = processed.frames.last.map { CMTimeGetSeconds($0.timestamp) } ?? 0
        print("""

        ━━━ zerro-extract ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        input:   \(inputURL.path)
        out:     \(outURL.path)
        frames:  \(frameCount)  (first=\(String(format: "%.2f", firstTs))s, last=\(String(format: "%.2f", lastTs))s)
        audio:   \(processed.audioURL.lastPathComponent)
        duration:\(String(format: "%.1f", CMTimeGetSeconds(processed.duration)))s
        manifest:\(outURL.appendingPathComponent("manifest.json").path)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        """)

        XCTAssertGreaterThan(frameCount, 0, "pipeline produced no frames")
        XCTAssertTrue(
            fm.fileExists(atPath: outURL.appendingPathComponent("manifest.json").path),
            "manifest.json missing from --out")
    }
}
