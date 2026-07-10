//
//  FreeSpaceGateTests.swift
//  ZerroTests
//
//  F-15 — the record-gate free-space decision. The old gate proceeded when
//  `WorkingDirectory.freeBytes()` returned nil (unreadable capacity), i.e.
//  "nil == OK" — a recording could start on a volume we couldn't size and be
//  lost at finalize. `AppState.shouldRefuseRecordingForFreeSpace` is the
//  factored-pure decision: nil now refuses, just like a below-threshold read.
//

import XCTest
@testable import Zerro

@MainActor
final class FreeSpaceGateTests: XCTestCase {

    func testUnreadableCapacityRefuses() {
        XCTAssertTrue(AppState.shouldRefuseRecordingForFreeSpace(nil))
    }

    func testBelowThresholdRefuses() {
        XCTAssertTrue(AppState.shouldRefuseRecordingForFreeSpace(
            AppState.minimumFreeBytesToRecord - 1
        ))
    }

    func testAtThresholdProceeds() {
        XCTAssertFalse(AppState.shouldRefuseRecordingForFreeSpace(
            AppState.minimumFreeBytesToRecord
        ))
    }

    func testPlentyOfSpaceProceeds() {
        XCTAssertFalse(AppState.shouldRefuseRecordingForFreeSpace(.max))
    }
}
