//
//  UpdateMajorPolicy.swift
//  Zerro
//
//  The major-version update boundary, applied to the Sparkle appcast. A
//  Zerro license covers every release of one major version — a 1.x.x
//  install is offered every 1.x.x update, and a future Zerro 2.x (which may
//  be sold separately) is NEVER auto-offered. The gate keys on the
//  MARKETING version (`sparkle:shortVersionString`, e.g. "1.4.33"), the
//  string that carries the product major; `sparkle:version` (the build
//  number) only ranks the allowed items.
//
//  Locked decisions:
//
//    • Allowed = items whose marketing-version major equals the RUNNING
//      app's own major. Every 1.x.x build offers all 1.x.x releases; a 2.x
//      build would offer 2.x the same way.
//    • FAIL-SAFE on malformed data — an item whose major can't be parsed is
//      never offered (silently skipped), and if the installed app's own
//      major can't be determined nothing is offered at all. The safe
//      failure is "you're up to date", never auto-installing a release the
//      user may not be licensed for.
//    • SILENT filtering — a filtered check finds the best allowed item
//      (possibly one the user already runs → "you're up to date"), never a
//      refusal or re-purchase dialog.
//
//  This boundary is STRICTLY about update offering. It never touches
//  license validity, activation, or the generation gate.
//
//  Split from the `SPUUpdaterDelegate` (UpdaterView.swift) so the decision
//  is a pure value-in/value-out function over plain `Candidate`s —
//  `SUAppcastItem`s aren't constructible in unit tests.
//

import Foundation
import Sparkle

enum UpdateMajorPolicy {

    /// The slice of an appcast item the decision needs: its
    /// `sparkle:version` (the build number, for ranking) and its marketing
    /// version (`SUAppcastItem.displayVersionString`, for the major gate).
    struct Candidate: Equatable {
        let version: String
        let marketingVersion: String?
    }

    /// What the updater delegate should do with this appcast.
    enum Decision: Equatable {
        /// Don't interfere — return `nil` so Sparkle runs its normal pick
        /// (every item is already the allowed major).
        case deferToSparkle
        /// Nothing offerable to this install — return the empty item so
        /// the check quietly reports "up to date".
        case noUpdate
        /// Offer `candidates[index]` — the highest-versioned allowed item.
        /// Sparkle still compares it against the installed version, so a
        /// user already on this build sees "up to date", not a reinstall.
        case bestAllowed(index: Int)
    }

    /// Parses the leading major from a marketing version string
    /// ("1.4.33" → 1). `nil` for a missing, empty, or non-numeric leading
    /// component — the caller treats that as "cannot verify" (fail-safe).
    static func major(ofMarketingVersion raw: String?) -> Int? {
        guard let raw else { return nil }
        let head = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return nil }
        return Int(trimmed)
    }

    /// The RUNNING app's own major, from its `CFBundleShortVersionString`.
    /// `nil` when the bundle's version is missing/malformed — the delegate
    /// then offers nothing (fail-safe).
    static func installedMajor(bundle: Bundle = .main) -> Int? {
        major(ofMarketingVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }

    /// The major-boundary decision. `allowedMajor == nil` means the running
    /// install's own major is unknown → offer NOTHING (fail-safe — never
    /// auto-install what can't be verified). An item whose marketing major
    /// is missing or unparseable is individually excluded the same way.
    static func decide(candidates: [Candidate], allowedMajor: Int?) -> Decision {
        guard let allowedMajor else { return .noUpdate }

        let allowed = candidates.indices.filter { index in
            major(ofMarketingVersion: candidates[index].marketingVersion) == allowedMajor
        }
        // Nothing filtered → stay out of Sparkle's way entirely.
        if allowed.count == candidates.count { return .deferToSparkle }
        guard !allowed.isEmpty else { return .noUpdate }

        // Highest sparkle:version among the allowed items, using Sparkle's
        // own comparator so "9" vs "10" orders numerically, exactly as the
        // updater itself would rank them.
        let comparator = SUStandardVersionComparator.default
        let best = allowed.max { a, b in
            comparator.compareVersion(candidates[a].version, toVersion: candidates[b].version) == .orderedAscending
        }
        // `allowed` is non-empty, so `max` can't miss; guard keeps this
        // total without a force-unwrap.
        guard let best else { return .deferToSparkle }
        return .bestAllowed(index: best)
    }
}
