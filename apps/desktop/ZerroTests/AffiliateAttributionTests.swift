//
//  AffiliateAttributionTests.swift
//  ZerroTests
//
//  Coverage for the affiliate-referral lookup the app runs just before opening a
//  checkout. The contract that matters: it resolves a code on a clean 200, and
//  on EVERY other path (null match, non-200, transport failure, garbage body) it
//  yields nil rather than throwing — so attribution never blocks a purchase.
//

import XCTest
@testable import Zerro

final class AffiliateAttributionTests: XCTestCase {

    /// Canned `ManagedTransport` — returns a fixed `(Data, status)` or throws,
    /// so the lookup's decode/branch logic is exercised with no network. Fields
    /// are value types (Sendable) to satisfy the `ManagedTransport: Sendable`.
    private struct StubTransport: ManagedTransport {
        var data: Data = Data()
        var status: Int = 200
        var throwsError: Bool = false
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            if throwsError { throw URLError(.timedOut) }
            return (data, status)
        }
    }

    func testReturnsCodeOnCleanMatch() async {
        let body = #"{"aff_ref":"ZylBs"}"#.data(using: .utf8)!
        let code = await AffiliateAttribution.referralCode(transport: StubTransport(data: body, status: 200))
        XCTAssertEqual(code, "ZylBs")
    }

    func testNilWhenNoMatch() async {
        let body = #"{"aff_ref":null}"#.data(using: .utf8)!
        let code = await AffiliateAttribution.referralCode(transport: StubTransport(data: body, status: 200))
        XCTAssertNil(code)
    }

    func testNilWhenAffRefEmpty() async {
        let body = #"{"aff_ref":""}"#.data(using: .utf8)!
        let code = await AffiliateAttribution.referralCode(transport: StubTransport(data: body, status: 200))
        XCTAssertNil(code)
    }

    func testNilOnNon200() async {
        let body = #"{"aff_ref":"ZylBs"}"#.data(using: .utf8)!
        let code = await AffiliateAttribution.referralCode(transport: StubTransport(data: body, status: 500))
        XCTAssertNil(code)
    }

    func testNilOnTransportFailure() async {
        let code = await AffiliateAttribution.referralCode(transport: StubTransport(throwsError: true))
        XCTAssertNil(code)
    }

    func testNilOnGarbageBody() async {
        let body = "not json".data(using: .utf8)!
        let code = await AffiliateAttribution.referralCode(transport: StubTransport(data: body, status: 200))
        XCTAssertNil(code)
    }
}
