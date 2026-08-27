//
//  SupportEmailTests.swift
//  ZerroTests
//
//  The support-email URL builder behind "Send Feedback". Pure URL
//  construction only — nothing here calls `SupportEmail.open()` or
//  launches any application.
//

import XCTest
@testable import Zerro

final class SupportEmailTests: XCTestCase {

    func testMailtoURLAddressesSupportWithSubject() throws {
        let url = try XCTUnwrap(SupportEmail.mailtoURL(appVersion: "1.5.0 (200)", macOSVersion: "15.6"))
        XCTAssertEqual(url.scheme, "mailto")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "support@getzerro.app")
        XCTAssertEqual(
            components.queryItems?.first { $0.name == "subject" }?.value,
            "Zerro feedback"
        )
    }

    func testBodyCarriesOnlyVersionContext() throws {
        let body = SupportEmail.body(appVersion: "1.5.0 (200)", macOSVersion: "Version 15.6 (Build 24G84)")
        XCTAssertTrue(body.contains("Zerro 1.5.0 (200)"))
        XCTAssertTrue(body.contains("macOS Version 15.6 (Build 24G84)"))
        // Nothing else rides along: no emails, keys, paths, or diagnostics.
        XCTAssertFalse(body.contains("@gmail"))
        XCTAssertFalse(body.contains("/Users/"))
        XCTAssertFalse(body.lowercased().contains("key"))
    }

    func testSubjectAndBodyArePercentEncoded() throws {
        let url = try XCTUnwrap(SupportEmail.mailtoURL(appVersion: "1.5.0 (200)", macOSVersion: "15.6"))
        let absolute = url.absoluteString
        // Raw spaces and newlines must never appear in the URL itself.
        XCTAssertFalse(absolute.contains(" "))
        XCTAssertFalse(absolute.contains("\n"))
        XCTAssertTrue(absolute.hasPrefix("mailto:support@getzerro.app?"))
        // Decoding through URLComponents restores the exact body.
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(
            components.queryItems?.first { $0.name == "body" }?.value,
            SupportEmail.body(appVersion: "1.5.0 (200)", macOSVersion: "15.6")
        )
    }

    func testHostileVersionStringsStillBuildAValidURL() {
        // Encoding must survive characters that are special in URLs.
        let url = SupportEmail.mailtoURL(appVersion: "1.0&x=1?y#z", macOSVersion: "??&&")
        XCTAssertNotNil(url, "encoding must never fail into a crash path")
    }
}
