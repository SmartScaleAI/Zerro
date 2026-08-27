//
//  SupportEmail.swift
//  Zerro
//
//  The "Send Feedback" action: opens the user's default email application
//  with a pre-addressed message to support. Entirely local — no network
//  request, no server relay, no stored addresses. The body carries only the
//  app and macOS versions (context any bug report needs); it never attaches
//  recordings, diagnostics, keys, or personal data.
//

import AppKit
import Foundation
import os

enum SupportEmail {

    static let address = "support@getzerro.app"
    static let subject = "Zerro feedback"

    /// The pre-filled body: a greeting line plus the version context, with a
    /// blank line for the user to write into. Pure over its inputs so tests
    /// can pin the exact contents.
    static func body(appVersion: String, macOSVersion: String) -> String {
        """


        —
        Zerro \(appVersion)
        macOS \(macOSVersion)
        """
    }

    /// Builds the `mailto:` URL with a percent-encoded subject and body, or
    /// nil if encoding fails (never crashes). Pure — tests exercise this
    /// without launching anything.
    static func mailtoURL(appVersion: String, macOSVersion: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body(appVersion: appVersion, macOSVersion: macOSVersion)),
        ]
        return components.url
    }

    /// Opens the default mail client with the pre-addressed message. Reads
    /// the live version strings; a URL that can't be built or opened is
    /// logged and otherwise a no-op — never a crash.
    @MainActor
    static func open() {
        let url = mailtoURL(
            appVersion: DiagnosticsCollector.displayVersionString(),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
        guard let url else {
            Log.ui.error("support email: mailto URL could not be built")
            return
        }
        if !NSWorkspace.shared.open(url) {
            Log.ui.error("support email: no application opened the mailto URL")
        }
    }
}
