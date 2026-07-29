//
//  ModelCountCopyGuardTests.swift
//  ZerroTests
//
//  A grep-style guard on the user-facing model COUNT, in the same spirit as
//  TranscriptionCopyGuardTests.
//
//  `gpt-5.4-mini` is kill-switched (enabled:false) but intentionally KEPT in the
//  registry so historic results still resolve its name — so the table holds six
//  entries while only five are selectable. Paywall/Billing copy shipped "all six
//  models" for a while after that flip. These tests pin both halves: the registry
//  shape, and the fact that no shipped copy hand-types a stale count.
//

import XCTest
@testable import Zerro

final class ModelCountCopyGuardTests: XCTestCase {

    /// Stale count phrasings that must never reach user-facing copy.
    private static let forbiddenPhrases = [
        "six models",
        "6 models",
        "all six",
        "across 6",
    ]

    // MARK: - Registry shape

    /// Pins the kill-switch shape the copy is derived from. If a model is added,
    /// removed, or re-enabled, this fails FIRST — the reminder to re-read the copy
    /// guards below rather than silently rewording them.
    func testRegistryHasSixEntriesWithFiveSelectable() {
        XCTAssertEqual(ModelRegistry.all.count, 6, "registry should hold 6 entries (5 selectable + the kill-switched mini)")
        XCTAssertEqual(ModelRegistry.enabled.count, 5, "exactly 5 models should be user-selectable")

        // The disabled one is the mini, and it stays resolvable for historic rows.
        let disabled = ModelRegistry.all.filter { !$0.enabled }
        XCTAssertEqual(disabled.map(\.id), ["gpt-5.4-mini"])
        XCTAssertNotNil(ModelRegistry.entry(id: "gpt-5.4-mini"), "kill-switched models must stay resolvable by id")
    }

    /// The spelled-out word tracks `enabled.count` (the copy voice uses words).
    func testSelectableCountWordMatchesTheRegistry() {
        XCTAssertEqual(ModelRegistry.selectableCountWord, "five")
    }

    // MARK: - Copy guards

    /// Every user-facing string on every `PaywallCopy` case, plus the Managed plan
    /// card subtitle, iterated so a future case with stale wording is caught too.
    private var allPaywallCopySurfaces: [(label: String, text: String)] {
        let cases: [(String, PaywallCopy)] = [
            ("blocked", .blocked),
            ("upgrade", .upgrade),
            ("topup", .topup),
            ("manage", .manage),
        ]
        var surfaces = cases.flatMap { name, copy in
            [
                (label: "\(name).headline", text: copy.headline),
                (label: "\(name).subheadline", text: copy.subheadline),
            ]
        }
        surfaces.append((label: "managedCardSubtitle", text: PaywallCopy.managedCardSubtitle))
        return surfaces
    }

    func testNoPaywallCopyClaimsASixModelCount() {
        for surface in allPaywallCopySurfaces {
            let lower = surface.text.lowercased()
            for phrase in Self.forbiddenPhrases {
                XCTAssertFalse(
                    lower.contains(phrase),
                    "\(surface.label) must not hand-type a stale model count — found \u{201C}\(phrase)\u{201D} in: \(surface.text)"
                )
            }
        }
    }

    /// Positive lock: the two paywall strings that DO state a count must state the
    /// derived one, not a literal. Keeps the guard above from passing on copy that
    /// simply dropped the number.
    func testCountingPaywallCopyIsDerivedFromTheRegistry() {
        let word = ModelRegistry.selectableCountWord
        XCTAssertTrue(
            PaywallCopy.upgrade.subheadline.contains("all \(word) models"),
            "the upgrade subheadline should state the derived model count"
        )
        XCTAssertTrue(
            PaywallCopy.managedCardSubtitle.contains("all \(word) models"),
            "the Managed card subtitle should state the derived model count"
        )
    }
}
