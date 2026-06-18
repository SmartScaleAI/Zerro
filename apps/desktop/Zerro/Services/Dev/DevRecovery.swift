//
//  DevRecovery.swift
//  Zerro
//
//  Dev Mode safety model (design §4, quit-recovery follow-up). Closes the last
//  "could lose work" path: a quit (⌘Q or `kill -9`) WHILE an agent dispatch is
//  mid-edit. `prepareForTermination` already terminates the agent and KEEPS the
//  git checkpoint snapshot on disk — but without a persisted pointer, the next
//  launch has no way to know that snapshot exists, so the user is left with
//  half-applied edits and no one-click undo.
//
//  `DevRecoveryMarker` is that pointer: the exact fields needed to rebuild the
//  `GitCheckpoint` + `GitCheckpointService` at next launch and offer an
//  Undo/Keep pill that reuses the already-verified `GitCheckpointService.revert`.
//  Nothing new is needed from GitCheckpoint — the checkpoint is fully
//  reconstructable from these fields + the project path.
//
//  `DevRecoveryStore` persists the marker as an ATOMIC JSON file under
//  Application Support (NOT UserDefaults): the marker must survive an abrupt
//  `kill -9`, not just a clean ⌘Q. `Data.write(options: .atomic)` flushes on
//  return, so a hard kill the instant after a dispatch starts still leaves a
//  readable marker.
//
//  Lifetime: the marker mirrors `AppState.devCheckpoint`'s lifetime, but
//  survives process death. It is written the instant the agent is first allowed
//  to edit (AFTER the confirmAnchors gate resolves to proceed) and cleared the
//  moment the checkpoint is torn down (accept / dismiss / cancel / revert).
//

import Foundation
import os

// MARK: - DevRecoveryMarker

/// The persisted pointer to an interrupted Dev Mode checkpoint. Carries exactly
/// the fields that reconstruct a `GitCheckpoint` (+ the project path that rebuilds
/// the `GitCheckpointService`), so a next-launch revert restores the pre-run tree
/// through the same code path an in-session Undo uses.
struct DevRecoveryMarker: Codable, Equatable {
    /// The project folder — rebuilds `GitCheckpointService(projectURL:)`.
    var projectPath: String
    /// HEAD at checkpoint time (the restore base when the tree was clean).
    var baseSha: String
    /// The `git stash create` snapshot commit, or nil when the tree was clean.
    var stashSha: String?
    /// The `dev-checkpoint-*` dir holding the saved untracked files, or nil when
    /// there were none. Validated to still exist before any offer (Part 3) — a
    /// revert that can't restore these must NOT run.
    var untrackedSnapshotPath: String?
    /// Repo-root-relative paths of the snapshotted untracked files.
    var untrackedRelativePaths: [String]
    /// When the dispatch started — for staleness reasoning + the offered analytics.
    var createdAt: Date
    /// The agent's display name, for the recovery pill copy. Optional — recovery
    /// works without it.
    var agentName: String?

    /// Rebuild the value `GitCheckpointService` needs to revert. The inverse of
    /// the fields captured at dispatch start; URLs are reconstructed from the
    /// stored path strings.
    var checkpoint: GitCheckpoint {
        GitCheckpoint(
            baseSha: baseSha,
            stashSha: stashSha,
            untrackedSnapshotDir: untrackedSnapshotPath.map { URL(fileURLWithPath: $0) },
            untrackedRelativePaths: untrackedRelativePaths
        )
    }

    /// The project folder URL — passed to `GitCheckpointService(projectURL:)`.
    var projectURL: URL { URL(fileURLWithPath: projectPath) }
}

// MARK: - PendingDevRecovery

/// The reconstructed, VALIDATED checkpoint being offered for cross-launch undo.
/// Built by `AppState.recoverInterruptedDevCheckpointIfAny` once every Part 3
/// safety check passes, held while the recovery pill is shown, and consumed by
/// `resolveDevRecovery(undo:)`. Carries the precomputed `diffStat` (which also
/// proved the restore ref resolves) so the pill copy renders without another git
/// call, and the `agentName` for that copy.
struct PendingDevRecovery {
    let checkpoint: GitCheckpoint
    let service: GitCheckpointService
    let diffStat: GitDiffStat
    let agentName: String?
}

// MARK: - DevRecoveryStore

/// Single owner of the persisted dev-recovery marker. Durability matters here —
/// the marker must survive `kill -9`, so it lives as an ATOMIC JSON file under
/// Application Support (not UserDefaults, which only flushes on a clean exit).
/// `save` / `load` / `clear` are the only operations; the on-disk checkpoint
/// snapshot itself (the `dev-checkpoint-*` dir) is owned by
/// `GitCheckpointService.discardSnapshot`, called alongside `clear()` at every
/// teardown.
final class DevRecoveryStore {

    private let fileURL: URL

    /// - Parameter fileURL: where the marker lives. Defaults to
    ///   `Application Support/Zerro/dev-recovery.json`. Injectable so tests use a
    ///   throwaway temp file and never touch the real on-disk marker.
    init(fileURL: URL = DevRecoveryStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// Atomically persist `marker`. Best-effort: a failed write only means a quit
    /// in the next instant won't be recoverable (the safe failure — the edits are
    /// simply kept), never a crash or a corrupt half-write (`.atomic` writes to a
    /// temp file then renames).
    func save(_ marker: DevRecoveryMarker) {
        do {
            try ensureParentDirectoryExists()
            let data = try Self.encoder.encode(marker)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            Log.dev.error("DevRecoveryStore save failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// The persisted marker, or nil if none is saved or it can't be decoded.
    func load() -> DevRecoveryMarker? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? Self.decoder.decode(DevRecoveryMarker.self, from: data)
    }

    /// Remove the persisted marker. Idempotent — safe when nothing is saved.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func ensureParentDirectoryExists() throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    /// `Application Support/Zerro/dev-recovery.json` — mirrors `RecentPromptStore`'s
    /// location convention. Falls back to the temp dir if Application Support is
    /// unreachable (exceptional; recovery just won't survive a relaunch then).
    static func defaultFileURL() -> URL {
        let base: URL
        do {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            Log.dev.error("applicationSupport unreachable for dev-recovery: \(error.localizedDescription, privacy: .private)")
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("dev-recovery.json")
        }
        return base
            .appendingPathComponent("Zerro", isDirectory: true)
            .appendingPathComponent("dev-recovery.json")
    }

    /// Epoch-seconds dates so the file is independent of any locale/wire
    /// formatting (mirrors the other on-disk stores).
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
