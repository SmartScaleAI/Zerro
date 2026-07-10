//
//  PendingPaidGeneration.swift
//  Zerro
//
//  Resume-after-purchase (M5). When a recording is processed but generation
//  is blocked at the proxy for a PAID reason — trial credits exhausted, out
//  of monthly credits, lapsed subscription — the recording is still intact
//  on disk. Rather than make the user re-record after they pay, we hold a
//  small pointer to that processed recording so the failure pill can offer a
//  "Continue" button that re-runs generation once they're entitled.
//
//  Two layers of persistence keep the held recording alive across a quit /
//  relaunch during browser checkout:
//    • This record, saved to `UserDefaults`, is the pointer restored at the
//      next launch (which working dir, which idempotency key, which reason).
//    • A copy written as a marker file (`pending-paid.json`) INSIDE the
//      working directory both doubles as the on-disk source of truth and
//      signals `WorkingDirectory.sweep()` to spare that directory (see
//      `WorkingDirectory.pendingPaidMarkerName`).
//

import Foundation

// MARK: - PaidBlockReason

/// The subset of `RecordingFailureReason` that represents a PAID block — the
/// only failures a "Continue after paying" resume applies to. A standalone,
/// `Codable` enum so the pending record can persist the blocking reason (the
/// `RecordingFailureReason` enum itself is not `Codable`) and restore the pill
/// with the right copy.
enum PaidBlockReason: String, Codable, Equatable {
    case trialCreditsExhausted
    case outOfCredits
    case subscriptionInactive

    /// Lifts a `RecordingFailureReason` into a `PaidBlockReason`, or `nil` for
    /// any non-paid reason (the resume feature ignores those).
    init?(_ reason: RecordingFailureReason) {
        switch reason {
        case .trialCreditsExhausted: self = .trialCreditsExhausted
        case .outOfCredits:          self = .outOfCredits
        case .subscriptionInactive:  self = .subscriptionInactive
        default:                     return nil
        }
    }

    /// The matching `RecordingFailureReason`, so a restored pill shows the same
    /// copy the live failure did.
    var failureReason: RecordingFailureReason {
        switch self {
        case .trialCreditsExhausted: return .trialCreditsExhausted
        case .outOfCredits:          return .outOfCredits
        case .subscriptionInactive:  return .subscriptionInactive
        }
    }
}

// MARK: - PendingPaidGeneration

/// A pointer to a processed recording whose generation was blocked for a paid
/// reason and is being held so the user can pay and resume. Everything here is
/// enough to reconstruct a `ProcessedRecording` from disk and re-run the
/// EXACT same generation (reusing `idempotencyKey` so the proxy replays a
/// charged-but-dropped response instead of double-charging).
struct PendingPaidGeneration: Codable, Equatable {
    /// The LAST PATH COMPONENT of the working directory (`zerro-work-<UUID>`),
    /// not an absolute path — the system temp dir can have a different prefix
    /// across launches, so we always resolve the name against the CURRENT
    /// `temporaryDirectory` (see `workingDirectoryURL`). This is also the name
    /// `WorkingDirectory.sweep()` inspects for the marker file.
    let workingDirectoryName: String
    /// The original recording's stable idempotency key, reused on resume so the
    /// proxy treats the resumed `/generate` as a replay of the blocked one.
    let idempotencyKey: String
    /// The model the blocked generation was priced against — passed through on
    /// resume so the recording isn't re-priced under a different model.
    let modelID: String
    /// Which paid block this was, so the restored pill shows matching copy.
    let reason: PaidBlockReason
    /// When the record was captured. Used to drop a stale pending record that
    /// has outlived any plausible checkout (see `PendingPaidGenerationStore`).
    let createdAt: Date

    /// The working directory URL resolved against the CURRENT temp dir.
    var workingDirectoryURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(workingDirectoryName, isDirectory: true)
    }
}

// MARK: - PendingPaidGenerationStore

/// Single owner of the persisted pending-paid pointer. Wraps `UserDefaults`
/// for the pointer and writes/removes the in-working-dir marker file in
/// lockstep, so the two never drift. `save` / `load` / `clear` are the only
/// operations; deleting the working directory itself stays with the caller
/// (AppState), which already owns working-dir cleanup.
final class PendingPaidGenerationStore {

    /// Records older than this are treated as orphaned — no real checkout takes
    /// a week. A restore that finds a record this old clears it and falls back
    /// to idle rather than re-surfacing an ancient recording. The same bar
    /// governs the marker file's sweep protection (F-16,
    /// `WorkingDirectory.hasFreshPendingPaidMarker`), so the pointer and the
    /// dir it shields age out together. `nonisolated`: read from the
    /// nonisolated sweep path (a plain immutable constant).
    nonisolated static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    private let defaults: UserDefaults
    private static let key = "pending_paid_generation_v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Persists `pending` to `UserDefaults` and writes the marker file into its
    /// working directory (the marker both protects the dir from `sweep()` and
    /// serves as the on-disk copy). Best-effort on the marker write — the
    /// `UserDefaults` pointer is the load-bearing copy; a failed marker write
    /// only risks the launch sweep reclaiming the dir, which the resume path
    /// already handles gracefully (it falls back to idle).
    func save(_ pending: PendingPaidGeneration) {
        guard let data = try? Self.encoder.encode(pending) else { return }
        defaults.set(data, forKey: Self.key)
        let marker = pending.workingDirectoryURL
            .appendingPathComponent(WorkingDirectory.pendingPaidMarkerName)
        try? data.write(to: marker, options: .atomic)
    }

    /// The persisted pending record, or `nil` if none is saved or it can't be
    /// decoded.
    func load() -> PendingPaidGeneration? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? Self.decoder.decode(PendingPaidGeneration.self, from: data)
    }

    /// Clears the persisted pointer and best-effort deletes the marker file
    /// (leaving the working directory itself for the caller to remove or keep).
    /// Idempotent — safe to call when nothing is saved or the dir is already
    /// gone.
    func clear() {
        if let pending = load() {
            let marker = pending.workingDirectoryURL
                .appendingPathComponent(WorkingDirectory.pendingPaidMarkerName)
            try? FileManager.default.removeItem(at: marker)
        }
        defaults.removeObject(forKey: Self.key)
    }

    /// Dates round-trip as epoch seconds so the cache is independent of any
    /// wire/locale formatting (mirrors `EntitlementStore`'s snapshot coders).
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
