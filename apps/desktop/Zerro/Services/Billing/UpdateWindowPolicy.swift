//
//  UpdateWindowPolicy.swift
//  Zerro
//
//  E7 / Appendix F — the BYOK "1 year of updates" window, applied to the
//  Sparkle appcast. The $69 BYOK license includes one year of updates from
//  the license's `created_at`; after that the installed build keeps working
//  but newer builds aren't offered. Locked decisions (F.0):
//
//    • Window = `created_at` + 1 calendar year, client-derived
//      (`LicenseService` persists the start; the math lives there too).
//    • BYOK ONLY — Managed subscribers are license-backed through the same
//      service but keep updating while subscribed; an unresolved product
//      kind is also never filtered (fail-open, mirrors the billing layer).
//    • FAIL-OPEN on missing data — no persisted window start (pre-E7
//      activation, Keychain read failure) means updates flow normally.
//      Missing data must never block a paying user's updates.
//    • SILENT filtering — an out-of-window check finds the best IN-window
//      item (possibly one the user already runs → "you're up to date"),
//      never a refusal dialog. No nag, no re-purchase prompt.
//
//  This window is STRICTLY about update offering. It must never touch
//  license validity, activation, or the generation gate — and it is NOT the
//  LS key-expiry `expires_at` (the F.2 trap: that flips validate to
//  `status:"expired"` → `isDefinitiveRevocation` → wrongly blocks
//  generation).
//
//  Split from the `SPUUpdaterDelegate` (UpdaterView.swift) so the decision
//  is a pure value-in/value-out function over plain `Candidate`s —
//  `SUAppcastItem`s aren't constructible in unit tests.
//

import Foundation
import Sparkle

enum UpdateWindowPolicy {

    /// The slice of an appcast item the window decision needs: its publish
    /// date (`<pubDate>` → `SUAppcastItem.date`) and its `sparkle:version`
    /// (the build number, for picking the best in-window item).
    struct Candidate: Equatable {
        let date: Date?
        let version: String
    }

    /// What the updater delegate should do with this appcast.
    enum Decision: Equatable {
        /// Don't interfere — return `nil` so Sparkle runs its normal pick
        /// (no window, or every item is inside it).
        case deferToSparkle
        /// Nothing publishable to this license — return the empty item so
        /// the check quietly reports "up to date".
        case noUpdate
        /// Offer `candidates[index]` — the highest-versioned in-window item.
        /// Sparkle still compares it against the installed version, so a
        /// user already on this build sees "up to date", not a reinstall.
        case bestInWindow(index: Int)
    }

    /// The window decision. `windowEnd == nil` means "no enforceable window"
    /// (not BYOK, or no persisted start) → defer. An item with NO publish
    /// date can't be window-checked and counts as in-window (per-item
    /// fail-open; our appcast pipeline always stamps `<pubDate>`, so this is
    /// a malformed-feed guard, not an expected path).
    static func decide(candidates: [Candidate], windowEnd: Date?) -> Decision {
        guard let windowEnd else { return .deferToSparkle }

        let inWindow = candidates.indices.filter { index in
            guard let date = candidates[index].date else { return true }
            return date <= windowEnd
        }
        // Nothing filtered → stay out of Sparkle's way entirely.
        if inWindow.count == candidates.count { return .deferToSparkle }
        guard !inWindow.isEmpty else { return .noUpdate }

        // Highest sparkle:version among the in-window items, using Sparkle's
        // own comparator so "9" vs "10" orders numerically, exactly as the
        // updater itself would rank them.
        let comparator = SUStandardVersionComparator.default
        let best = inWindow.max { a, b in
            comparator.compareVersion(candidates[a].version, toVersion: candidates[b].version) == .orderedAscending
        }
        // `inWindow` is non-empty, so `max` can't miss; guard keeps this
        // total without a force-unwrap.
        guard let best else { return .deferToSparkle }
        return .bestInWindow(index: best)
    }

    /// The enforceable window end for the CURRENT install, or `nil` for
    /// "don't filter": the on-file license isn't explicitly BYOK (Managed, or
    /// kind not yet resolved — both must keep updating), or no window start
    /// is persisted/parseable (fail-open). Slots are injectable for tests;
    /// production passes the real Keychain slots (see `UpdaterViewModel`).
    static func currentWindowEnd(
        kindSlot: KeychainSlot,
        createdAtSlot: KeychainSlot
    ) -> Date? {
        guard case .found(let kind) = kindSlot.readResult(),
              kind == LicenseProductKind.byok.rawValue else { return nil }
        guard case .found(let raw) = createdAtSlot.readResult(),
              let seconds = TimeInterval(raw) else { return nil }
        return LicenseService.updateWindowEnd(createdAt: Date(timeIntervalSince1970: seconds))
    }
}
