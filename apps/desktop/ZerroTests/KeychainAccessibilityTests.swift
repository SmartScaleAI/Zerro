//
//  KeychainAccessibilityTests.swift
//  ZerroTests
//
//  E-03 — per-slot Keychain protection classes: the local trial-clock slots
//  are …ThisDeviceOnly (excluded from encrypted backups / Migration Assistant
//  — a migrated Mac gets its own trial), while every license and
//  provider-key slot stays AfterFirstUnlock (must survive a backup restore).
//  The InMemoryKeychainSlot fake doesn't model kSecAttrAccessible, so this
//  pins the CONFIGURATION; write()'s use of it is review + build verified.
//

import XCTest
@testable import Zerro

@MainActor
final class KeychainAccessibilityTests: XCTestCase {

    func testTrialSlotsAreThisDeviceOnly() {
        let expected = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        XCTAssertEqual(KeychainStore.trialStartDate.accessible as String, expected)
        XCTAssertEqual(KeychainStore.trialMaxDateSeen.accessible as String, expected)
    }

    func testLicenseByokAndProviderSlotsStayAfterFirstUnlock() {
        let expected = kSecAttrAccessibleAfterFirstUnlock as String
        let restorableSlots: [KeychainStore] = [
            .openAIAPIKey,
            .geminiAPIKey,
            .anthropicAPIKey,
            .byokLicenseKey,
            .byokInstanceID,
            .byokLastValidated,
            .licensedProductID,
            .licensedMajor,
        ]
        for slot in restorableSlots {
            XCTAssertEqual(
                slot.accessible as String,
                expected,
                "slot \(slot.account) must stay backup/migration-restorable"
            )
        }
    }
}
