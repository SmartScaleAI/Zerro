//
//  WorkingDirectory.swift
//  VisualFlowAI
//
//  Created by Colin Breeding on 5/28/26.
//
//  Each recording's processing output (isolated audio, frames, manifest)
//  lives in its own UUID-named subdirectory under the system temp dir.
//  The `visualflow-work-` prefix lets the launch-sweep (Step 5) identify
//  our own orphaned directories without touching unrelated tmp content.
//  The broader `visualflow-` family also covers source .mov recordings
//  written by RecordingSession, so a single sweep clears both.
//
//  Cleanup policy (Step 5)
//  -----------------------
//  • Launch-sweep (`sweep()`) — called once at app launch from
//    VisualFlowAIApp's one-shot init block. Deletes every entry in tmp
//    whose name starts with `visualflow-` (recordings + working dirs).
//    Targets orphans from crashes / force-quits — anything alive in the
//    current run is constructed AFTER sweep runs, so it can't clobber
//    a live artifact.
//  • Per-session (`remove(at:)`) — used by AppState to delete a
//    specific source .mov after successful processing, and the prior
//    session's working directory when a new recording starts.
//  • Pipeline-internal — ProcessingPipeline.process() catches its own
//    throws and deletes the partial working directory before
//    re-throwing, so a mid-pipeline failure doesn't leak a half-built
//    directory the user has to wait for sweep to clear.
//

import Foundation

enum WorkingDirectory {

    /// Filename prefix shared by source recordings (`visualflow-*.mov`)
    /// and processing working directories (`visualflow-work-*/`). The
    /// launch-sweep matches on this prefix to clear both families in
    /// one pass.
    static let prefix = "visualflow-"

    /// Filename prefix for processing working directories specifically.
    /// Used by `make()` to disambiguate from raw recordings.
    static let workingPrefix = "visualflow-work-"

    /// Creates a fresh UUID-named working directory under the system temp
    /// dir and returns its URL. The caller owns the returned directory's
    /// lifecycle — pipeline failure → pipeline deletes; new recording →
    /// AppState deletes the prior one; crash → sweep catches at next
    /// launch.
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(workingPrefix)\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
        } catch {
            throw ProcessingError.workingDirectoryCreationFailed(underlying: error)
        }
        return url
    }

    /// Best-effort delete of a URL (file or directory). Silently no-ops
    /// if the path doesn't exist or can't be removed — cleanup is never
    /// load-bearing for correctness, and surfacing a "couldn't delete
    /// tmp" error to the user is worse than leaving the artifact for
    /// the next launch-sweep.
    static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Scans `NSTemporaryDirectory()` and deletes every entry whose
    /// basename starts with `prefix` (`visualflow-`). Run once at app
    /// launch. Anything created in the current run is created AFTER
    /// this call, so we can't accidentally clobber a live artifact.
    /// Failures are logged + ignored — sweep is best-effort.
    static func sweep() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: tmp,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            NSLog("[Cleanup] sweep: couldn't list tmp: %@", String(describing: error))
            return
        }

        var removed = 0
        for entry in contents where entry.lastPathComponent.hasPrefix(prefix) {
            do {
                try fm.removeItem(at: entry)
                removed += 1
            } catch {
                NSLog(
                    "[Cleanup] sweep: couldn't remove %@: %@",
                    entry.lastPathComponent,
                    String(describing: error)
                )
            }
        }
        if removed > 0 {
            NSLog("[Cleanup] sweep removed %d orphaned entries", removed)
        }
    }
}
