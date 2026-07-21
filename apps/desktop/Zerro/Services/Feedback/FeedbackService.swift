//
//  FeedbackService.swift
//  Zerro
//
//  Created by Colin Breeding on 6/15/26.
//
//  The networking half of the in-app feedback dialog (FeedbackView). POSTs the
//  user's message to the `feedback` Supabase Edge Function, which relays it to a
//  Slack channel (the webhook URL is server-held — never in the client). The
//  endpoint is UNAUTHENTICATED (the dialog works signed-out), exactly like
//  `trial-start`, so this sends no bearer token and shares only the public
//  `ManagedBackend.baseURL` resolution.
//
//  Wire shape (matches supabase/functions/feedback/index.ts):
//    POST /feedback
//    { "kind": "issue" | "feedback",
//      "message": <string>, "app_version": <string>, "os_version": <string>,
//      "user_email": <string|null> }
//    → 200 { ok: true }
//
//  Privacy: the message body is user content — it is NEVER logged at info level
//  (only its length + the kind + the HTTP outcome are recorded).
//

import Foundation
import os

// MARK: - FeedbackKind

/// Which dialog tab the submission came from. The raw value is the `kind` field
/// the edge function validates against its allow-list.
enum FeedbackKind: String, Equatable {
    case issue
    case feedback
}

// MARK: - FeedbackError

/// Typed failures the dialog renders as its inline error state. The message is
/// preserved by the view across a retry, so none of these are terminal.
enum FeedbackError: Error, Equatable {
    /// The trimmed message was empty — caught client-side before any request.
    case emptyMessage
    /// Couldn't reach the backend (offline / DNS / timeout). Retryable.
    case network(String)
    /// The backend rejected the submission or Slack delivery failed (any
    /// non-2xx). Retryable.
    case server(status: Int)
    /// Response wasn't the shape we expected (should be unreachable on 2xx).
    case malformedResponse

    /// User-facing one-liner for the dialog's inline error row.
    var userMessage: String {
        switch self {
        case .emptyMessage:
            return "Enter a message before sending."
        case .network:
            return "Couldn\u{2019}t reach the server. Check your connection and try again."
        case .server:
            return "Couldn\u{2019}t send your feedback. Please try again."
        case .malformedResponse:
            return "Something went wrong sending your feedback. Please try again."
        }
    }
}

// MARK: - FeedbackService

/// Submits feedback / issue reports to the `feedback` edge function. Stateless;
/// constructed on demand by the dialog. Networking goes through a dedicated
/// `URLSession` with a short timeout — a feedback POST is a tiny JSON body, so
/// it should fail fast rather than hang the dialog's sending state.
@MainActor
final class FeedbackService {

    /// Hard cap on the message length, mirrored by the edge function. The
    /// dialog also caps the editor, so this is a defensive backstop.
    static let messageMaxLength = 4000

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? FeedbackService.makeSession()
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    /// Trims + validates the message, then POSTs it. Throws `FeedbackError` on
    /// every failure path; returns normally on a 2xx.
    ///
    /// `userEmail` is the signed-in account email when known (read from the
    /// trial-credits layer's remembered email), or `nil` when signed out — the
    /// dialog works in both cases and the server records "not signed in".
    func submit(
        kind: FeedbackKind,
        message: String,
        userEmail: String?
    ) async throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FeedbackError.emptyMessage }
        let capped = String(trimmed.prefix(Self.messageMaxLength))

        let body = try encodeBody(kind: kind, message: capped, userEmail: userEmail)

        var request = URLRequest(url: ManagedBackend.feedbackURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        Log.feedback.notice(
            "submitting feedback — kind=\(kind.rawValue, privacy: .public) length=\(capped.count, privacy: .public) signedIn=\(userEmail != nil ? "Y" : "N", privacy: .public)"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Log.feedback.error("feedback transport failure: \(error.localizedDescription, privacy: .public)")
            throw FeedbackError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FeedbackError.malformedResponse
        }

        guard (200...299).contains(http.statusCode) else {
            Log.feedback.error("feedback rejected — status=\(http.statusCode, privacy: .public)")
            throw FeedbackError.server(status: http.statusCode)
        }

        // Confirm the success shape. The body is `{ ok: true }`; a 2xx that
        // doesn't decode is treated as malformed rather than silently accepted.
        struct FeedbackResponseDTO: Decodable { let ok: Bool }
        guard let decoded = try? JSONDecoder().decode(FeedbackResponseDTO.self, from: data),
              decoded.ok else {
            throw FeedbackError.malformedResponse
        }

        Log.feedback.notice("feedback delivered — kind=\(kind.rawValue, privacy: .public)")
    }

    // MARK: - Encode

    /// Builds the request body. `app_version` / `os_version` are read from the
    /// shared `DiagnosticsCollector` helpers so the Slack message carries the
    /// same version strings a support email would. `user_email` is sent as JSON
    /// `null` when signed out.
    private func encodeBody(
        kind: FeedbackKind,
        message: String,
        userEmail: String?
    ) throws -> Data {
        let payload: [String: Any] = [
            "kind": kind.rawValue,
            "message": message,
            "app_version": DiagnosticsCollector.appVersionString(),
            "os_version": DiagnosticsCollector.osVersionString(),
            // NSNull bridges to JSON `null` — the field is always present so the
            // server's optional-string parse sees an explicit absence.
            "user_email": userEmail ?? NSNull(),
        ]

        do {
            return try JSONSerialization.data(withJSONObject: payload)
        } catch {
            // Encoding our own small payload shouldn't fail; surface as malformed.
            throw FeedbackError.malformedResponse
        }
    }
}
