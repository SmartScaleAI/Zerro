//
//  KeychainAccessibilityTests.swift
//  ZerroTests
//
//  E-03 — per-slot Keychain protection classes: the TRIAL slots are
//  …ThisDeviceOnly (excluded from encrypted backups / Migration Assistant —
//  the grant is device-bound server-side), while every license/BYOK and
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
        XCTAssertEqual(KeychainStore.trialEmail.accessible as String, expected)
        XCTAssertEqual(KeychainStore.trialToken.accessible as String, expected)
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
            .byokLicenseCreatedAt,
            .licenseProductKind,
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
