//
//  WorkingDirectory.swift
//  Zerro
//
//  Created by Colin Breeding on 5/28/26.
//
//  Each recording's processing output (isolated audio, frames, manifest)
//  lives in its own UUID-named subdirectory under the system temp dir.
//  The `zerro-work-` prefix lets the launch-sweep (Step 5) identify
//  our own orphaned directories without touching unrelated tmp content.
//  The broader `zerro-` family also covers source .mov recordings
//  written by RecordingSession, so a single sweep clears both.
//
//  Cleanup policy (Step 5)
//  -----------------------
//  • Launch-sweep (`sweep()`) — called once at app launch from
//    ZerroApp's one-shot init block. Deletes every entry in tmp
//    whose name starts with `zerro-` (recordings + working dirs).
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
//  DEBUG eval retention (Phase 0)
//  ------------------------------
//  In DEBUG builds, the `-RetainEvalArtifacts YES` launch arg makes every
//  `remove(at:)` a no-op (see `retainEvalArtifacts`), so a recording's raw
//  `.mov` and working dir both survive for the eval corpus. `sweep()` is
//  intentionally left ungated, so the next launch still reclaims tmp.
//  Compiled out of RELEASE — production cleanup is unchanged.
//

import Foundation
import os

enum WorkingDirectory {

    /// Filename prefix shared by source recordings (`zerro-*.mov`)
    /// and processing working directories (`zerro-work-*/`). The
    /// launch-sweep matches on this prefix to clear both families in
    /// one pass.
    nonisolated static let prefix = "zerro-"

    /// Filename prefix for processing working directories specifically.
    /// Used by `make()` to disambiguate from raw recordings.
    static let workingPrefix = "zerro-work-"

    /// Sidecar suffix that marks a source `.mov` as DELIBERATELY abandoned —
    /// the sleep-interruption or quit-while-recording paths in
    /// `RecordingSession.abandon()` write `zerro-<UUID>.mov.recoverable` next
    /// to the fragment. `orphanedRecordings()` offers ONLY `.mov`s that carry
    /// this marker, so a recording left by something OTHER than a deliberate
    /// abandon — an Xcode/crash SIGKILL mid-record, or a completed recording
    /// the `-RetainEvalArtifacts` switch kept on disk — has no marker and is
    /// swept, never falsely offered as "stopped when your Mac slept". The
    /// marker shares the `zerro-` prefix, so the launch `sweep()` reclaims it
    /// alongside everything else.
    nonisolated static let recoverableMarkerSuffix = "recoverable"

    /// Filename of the marker dropped INSIDE a `zerro-work-` directory whose
    /// recording is being held for a paid-block resume (M5 — see
    /// `PendingPaidGeneration`). Its presence tells `sweep()` to spare that
    /// directory across launches so the recording survives a quit during
    /// browser checkout; the file's contents are a copy of the pending record.
    /// Unlike `recoverableMarkerSuffix` (a sidecar NEXT TO a `.mov`), this lives
    /// inside the working dir, so the sweep checks for it per-directory.
    nonisolated static let pendingPaidMarkerName = "pending-paid.json"

    /// Best-effort, synchronous: drop the recoverable marker next to `movURL`.
    /// Called from `abandon()` BEFORE the async writer release so the marker
    /// exists even if the app exits moments later (the quit-while-recording
    /// path). The `.mov` itself already exists (the writer created it).
    nonisolated static func markRecoverable(_ movURL: URL) {
        let marker = movURL.appendingPathExtension(recoverableMarkerSuffix)
        try? Data().write(to: marker, options: .atomic)
    }

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

    #if DEBUG
    /// DEBUG-only eval switch (Phase 0). When set — via the Xcode "Zerro"
    /// scheme launch arg `-RetainEvalArtifacts YES`, which lands in
    /// `UserDefaults` under this key — EVERY routine per-artifact delete
    /// routed through `remove(at:)` is skipped, so a recording's raw
    /// `zerro-<UUID>.mov` AND its `zerro-work-<UUID>` working dir both
    /// survive a full record → generate cycle. That's what lets the eval
    /// corpus (`Scripts/capture-recording.sh`) grab the source `.mov` and
    /// re-run `ProcessingPipeline` on it later (`zerro-extract`) when a
    /// future phase changes sampling/resolution.
    ///
    /// Read ONCE at first access (a launch arg can't change mid-run).
    /// `nonisolated` because `remove(at:)` is, and the project's
    /// `-default-isolation=MainActor` would otherwise pin this static to
    /// the main actor; `UserDefaults` reads are thread-safe.
    ///
    /// Deliberately scoped to `remove(at:)` and NOTHING else: the
    /// launch-time orphan `sweep()` calls `FileManager.removeItem`
    /// directly, so it is NOT gated — tmp is still reclaimed at the next
    /// launch and retained artifacts can't accumulate unboundedly across
    /// sessions. The entire mechanism is compiled out of RELEASE builds,
    /// so production cleanup behaves exactly as before.
    nonisolated static let retainEvalArtifacts: Bool =
        UserDefaults.standard.bool(forKey: "RetainEvalArtifacts")
    #endif

    /// Best-effort delete of a URL (file or directory). Silently no-ops
    /// if the path doesn't exist or can't be removed — cleanup is never
    /// load-bearing for correctness, and surfacing a "couldn't delete
    /// tmp" error to the user is worse than leaving the artifact for
    /// the next launch-sweep.
    nonisolated static func remove(at url: URL) {
        #if DEBUG
        // Eval-retention escape hatch (DEBUG only). Skip the delete so the
        // source `.mov` / working dir persist for the eval corpus. Basename
        // is .public (a `zerro-*` name we generated, no user content).
        if retainEvalArtifacts {
            Log.cleanup.notice(
                "RetainEvalArtifacts: keeping \(url.lastPathComponent, privacy: .public)"
            )
            return
        }
        #endif
        try? FileManager.default.removeItem(at: url)
    }

    /// Free bytes available on the volume that backs our temp directory
    /// — the disk we'll write the recording, audio.m4a, and frames to.
    /// Returns nil if the OS won't give us a number (extremely rare;
    /// failures here shouldn't block the recording, so callers should
    /// treat nil as "assume we have space" rather than refuse to start).
    ///
    /// `volumeAvailableCapacityForImportantUsageKey` is the right key
    /// here: it reflects what's *actually* available to a user-initiated
    /// write after the system reclaims purgeable / cached content,
    /// matching what the user sees in About This Mac → Storage. The
    /// older `volumeAvailableCapacityKey` undercounts by the size of
    /// purgeable content and would refuse recordings the OS would
    /// actually have happily accommodated.
    static func freeBytes() -> Int64? {
        let tempURL = FileManager.default.temporaryDirectory
        do {
            let values = try tempURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            return values.volumeAvailableCapacityForImportantUsage
        } catch {
            // Error description marked .private — volume URL errors
            // typically embed the full path of the failing volume.
            Log.cleanup.error(
                "freeBytes: couldn’t read volume capacity: \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    /// Source recordings (`zerro-*.mov`) left in the temp dir by a prior
    /// session, newest first by modification date. Excludes working dirs
    /// (`zerro-work-*`) and any non-`.mov` entries. M2 (rev 2) launch
    /// recovery uses this to find a sleep-interrupted recording to salvage
    /// before `sweep` clears the remaining junk. Best-effort: returns [] if
    /// the temp dir can't be listed.
    nonisolated static func orphanedRecordings() -> [URL] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        func modDate(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        // Only a `.mov` with its sidecar `.recoverable` marker was deliberately
        // abandoned (sleep / quit-while-recording). An unmarked `.mov` — a
        // SIGKILL/crash leftover or an eval-retained completed recording — is
        // NOT offered; `sweepIfLaunch` reclaims it instead.
        let names = Set(contents.map(\.lastPathComponent))
        return contents
            .filter {
                let name = $0.lastPathComponent
                return name.hasPrefix(prefix)
                    && !name.hasPrefix(workingPrefix)
                    && $0.pathExtension == "mov"
                    && names.contains("\(name).\(recoverableMarkerSuffix)")
            }
            .sorted { modDate($0) > modDate($1) }
    }

    /// Scans `NSTemporaryDirectory()` and deletes every entry whose
    /// basename starts with `prefix` (`zerro-`), EXCEPT `keep` (the one
    /// recording M2 launch recovery is about to salvage; nil → delete all,
    /// the original behavior). Run once at app launch. Anything created in
    /// the current run is created AFTER this call, so we can't accidentally
    /// clobber a live artifact. Failures are logged + ignored — best-effort.
    nonisolated static func sweep(keeping keep: URL? = nil) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let keepPath = keep?.standardizedFileURL.path
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: tmp,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            Log.cleanup.error("sweep: couldn't list tmp: \(error.localizedDescription, privacy: .private)")
            return
        }

        var removed = 0
        for entry in contents where entry.lastPathComponent.hasPrefix(prefix) {
            if let keepPath, entry.standardizedFileURL.path == keepPath { continue }
            // M5: a working dir holding a paid-block recording (Continue-after-pay)
            // carries the pending-paid marker. Spare it so the recording survives
            // a quit during checkout — the restore path / an intentional dismiss
            // is the only thing that removes it. Cheap best-effort file probe;
            // genuinely orphaned `zerro-work-` dirs (no marker) are still reclaimed.
            if containsPendingPaidMarker(entry) { continue }
            do {
                try fm.removeItem(at: entry)
                removed += 1
            } catch {
                // The basename is .public — it's a `zerro-*` name we
                // generated ourselves, no user content. The error
                // description is .private (paths).
                Log.cleanup.error(
                    "sweep: couldn't remove \(entry.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)"
                )
            }
        }
        if removed > 0 {
            Log.cleanup.notice("sweep removed \(removed, privacy: .public) orphaned entries")
        }
    }

    /// Whether `dir` contains the pending-paid marker file — i.e. it holds a
    /// recording being held for a Continue-after-pay resume. Best-effort: any
    /// failure (not a directory, unreadable) reads as "no marker", so the sweep
    /// errs toward reclaiming rather than leaking. Cheap existence check, no read.
    nonisolated static func containsPendingPaidMarker(_ dir: URL) -> Bool {
        let marker = dir.appendingPathComponent(pendingPaidMarkerName)
        return FileManager.default.fileExists(atPath: marker.path)
    }
}
