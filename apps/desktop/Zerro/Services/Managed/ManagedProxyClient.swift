//
//  ManagedProxyClient.swift
//  Zerro
//
//  Created by Colin Breeding on 6/2/26.
//
//  Overview
//  --------
//  Phase E — the Managed generation path. Where BYOK transcribes + composes
//  locally and calls OpenAI directly, the Managed path uploads the recording's
//  AUDIO + FRAMES + the output MODE to the Supabase `generate` proxy and gets
//  the finished prompt back. The server owns transcription and the system
//  prompt (§6.1) — so this client sends NEITHER a transcript NOR a prompt; that
//  is the control that stops a paying user repurposing the Zerro OpenAI key as
//  a general LLM (§14.1). The client supplies only the `mode` enum, which is
//  the one input that steers the (server-owned) prompt.
//
//  Wire shape (matches `supabase/functions/generate/limits.ts`):
//    POST /generate   Authorization: Bearer <session token>
//    {
//      "mode": "instruct" | "explain",
//      "audio":  { "mime": "audio/m4a", "filename": "recording.m4a",
//                  "data": "<base64>", "duration_seconds": 42.0 },
//      "frames": [ { "timestamp": 0.0, "mime": "image/jpeg", "data": "<base64>" }, … ]
//    }
//  Response (200): { "prompt": "...", "usage": { input_tokens, output_tokens, model },
//                    "credits_remaining": N }
//
//  Token lifecycle: a token that expires mid-use is refreshed transparently —
//  on a `401` we mint a fresh token and retry ONCE, then fail. The raw license
//  key never appears in a `/generate` request (it lives in `SessionTokenManager`
//  and rides only to `/session`).
//
//  Errors map to the app's existing failure taxonomy at the AppState call site
//  (`RecordingFailureReason`): out-of-credits → a clear non-punitive case;
//  cancelled/expired subscription → not-entitled; 5xx/timeout → the existing
//  retryable provider-error path.
//

import CoreMedia
import Foundation
import os

// MARK: - ManagedGenerationError

/// Typed failures of a Managed `/generate` call. AppState maps these to
/// `RecordingFailureReason` for the pill. Kept as its own taxonomy (rather than
/// reusing `PromptGenerationError`) because the Managed path has failure modes
/// the BYOK path doesn't (out-of-credits, subscription lapsed, session expiry).
enum ManagedGenerationError: Error, Equatable {
    /// `402` — the current period's credits are spent. Non-punitive copy +
    /// "resets {date}" + upgrade CTA live in the UI; generation is blocked
    /// (the server enforces it too).
    case outOfCredits
    /// `403`/`404` — the subscription is no longer active (cancelled/expired)
    /// or the session resolved to nothing. Routes the user back to the paywall.
    case notEntitled
    /// `429` — per-subscriber rate limit or concurrency cap hit. Retryable.
    case rateLimited
    /// `401` even AFTER a fresh-token retry — a real auth problem, not a
    /// routine mid-use expiry (those are refreshed transparently).
    case authFailed
    /// `413`/`415`/`400` — the server-side input fuse rejected the payload. A
    /// real recording can't trip this; treated as a provider-class error.
    case inputRejected(String)
    /// `502`/`503`/`5xx` — the proxy or OpenAI is unavailable. Retryable.
    case providerUnavailable
    /// Transport failure (offline/DNS/timeout). Retryable / offline-class.
    case network(String)
    /// The success body wasn't the JSON shape we expected.
    case malformedResponse
    /// A frame/audio artifact couldn't be read off disk to upload.
    case artifactUnreadable
}

// MARK: - ManagedGenerationResult

/// The proxy's result: the same `PromptGenerationResult` the BYOK path produces
/// (so the pill/clipboard/history path is identical) plus the server's
/// post-decrement credit balance, which the UI uses to update the credits line
/// immediately (before the authoritative `/entitlement` refresh lands).
struct ManagedGenerationResult {
    let result: PromptGenerationResult
    /// `credits_remaining` from the server, or `nil` if the body omitted it.
    let creditsRemaining: Int?
}

// MARK: - ManagedProxyClient

@MainActor
final class ManagedProxyClient {

    private let sessionTokens: SessionTokenManager
    private let transport: ManagedTransport

    init(sessionTokens: SessionTokenManager, transport: ManagedTransport? = nil) {
        self.sessionTokens = sessionTokens
        self.transport = transport ?? URLSessionManagedTransport()
    }

    /// Runs a proxy generation: reads the audio + frames off disk, base64s them
    /// with the mode, POSTs to `/generate` with a bearer token, and parses the
    /// returned prompt. A `401` triggers exactly one transparent token refresh +
    /// retry. Throws `ManagedGenerationError` on every failure path.
    ///
    /// `tokenProvider` selects the credential: the default Managed
    /// `SessionTokenManager` (a subscription token) or — passed by the trial
    /// path (Phase F) — a `TrialCreditsManager` (a trial token). The wire shape,
    /// flow, and error mapping are identical; only the token's `kind` differs,
    /// which the SERVER uses to pick the credit ledger.
    func generate(
        audioURL: URL,
        frames: [ExtractedFrame],
        mode: OutputMode,
        durationSeconds: Double?,
        tokenProvider: ProxyTokenProviding? = nil
    ) async throws -> ManagedGenerationResult {
        let provider: ProxyTokenProviding = tokenProvider ?? sessionTokens
        // Flatten the frames to a Sendable representation on the current actor,
        // then build the (key-free) request body OFF the main actor — reading
        // and base64-ing a multi-MB audio + frame payload would otherwise hitch
        // the UI (the BYOK path likewise encodes off-main). The same bytes are
        // reused on the post-refresh retry.
        let uploads = frames.map { FrameUpload(url: $0.url, timestamp: CMTimeGetSeconds($0.timestamp)) }
        let body = try await Task.detached(priority: .userInitiated) {
            try Self.encodeBody(
                audioURL: audioURL,
                frames: uploads,
                mode: mode,
                durationSeconds: durationSeconds
            )
        }.value

        // First attempt with the cached/fresh token.
        let token = try await token(from: provider)
        var (data, status) = try await post(body: body, token: token)

        // 401 → token expired/rotated mid-use. Refresh once and retry. A second
        // 401 is a genuine auth failure, not a routine expiry. (For the trial
        // provider a refresh can't silently re-mint — it throws — so a mid-use
        // expiry surfaces as authFailed, which the call site treats as "re-verify
        // your email".)
        if status == 401 {
            Log.billing.notice("generate 401 — refreshing token and retrying once")
            let refreshed: String
            do {
                refreshed = try await provider.refreshToken()
            } catch {
                throw ManagedGenerationError.authFailed
            }
            (data, status) = try await post(body: body, token: refreshed)
            if status == 401 { throw ManagedGenerationError.authFailed }
        }

        return try Self.parse(data: data, status: status)
    }

    // MARK: - Token

    private func token(from provider: ProxyTokenProviding) async throws -> String {
        do {
            return try await provider.validToken()
        } catch ManagedSessionError.network(let desc) {
            throw ManagedGenerationError.network(desc)
        } catch ManagedSessionError.notEntitled {
            throw ManagedGenerationError.notEntitled
        } catch ManagedSessionError.rateLimited {
            throw ManagedGenerationError.rateLimited
        } catch {
            throw ManagedGenerationError.authFailed
        }
    }

    // MARK: - POST

    private func post(body: Data, token: String) async throws -> (Data, Int) {
        var request = URLRequest(url: ManagedBackend.generateURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        do {
            return try await transport.send(request)
        } catch {
            throw ManagedGenerationError.network(error.localizedDescription)
        }
    }

    // MARK: - Encode

    /// A frame to upload, flattened to Sendable primitives (URL + seconds) so
    /// `encodeBody` can run off the main actor.
    struct FrameUpload: Sendable {
        let url: URL
        let timestamp: Double
    }

    /// Builds the `/generate` JSON body. Audio + each frame are read off disk
    /// and base64-encoded here, at request-build time — the 33% overhead is
    /// dropped after the request, never held on the in-memory timeline (mirrors
    /// the BYOK `base64DataURL` discipline). `nonisolated` so it runs in a
    /// detached task off the main actor.
    nonisolated static func encodeBody(
        audioURL: URL,
        frames: [FrameUpload],
        mode: OutputMode,
        durationSeconds: Double?
    ) throws -> Data {
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw ManagedGenerationError.artifactUnreadable
        }

        var audio: [String: Any] = [
            "mime": ManagedBackend.audioMime,
            "filename": ManagedBackend.audioFilename,
            "data": audioData.base64EncodedString(),
        ]
        if let durationSeconds, durationSeconds.isFinite, durationSeconds >= 0 {
            audio["duration_seconds"] = durationSeconds
        }

        var frameObjects: [[String: Any]] = []
        frameObjects.reserveCapacity(frames.count)
        for frame in frames {
            let frameData: Data
            do {
                frameData = try Data(contentsOf: frame.url)
            } catch {
                throw ManagedGenerationError.artifactUnreadable
            }
            frameObjects.append([
                "timestamp": frame.timestamp,
                "mime": ManagedBackend.frameMime,
                "data": frameData.base64EncodedString(),
            ])
        }

        // `mode` is the ONLY field that steers the server-owned prompt — no
        // transcript, no system prompt (§6.1).
        let payload: [String: Any] = [
            "mode": mode.rawValue,
            "audio": audio,
            "frames": frameObjects,
        ]

        do {
            return try JSONSerialization.data(withJSONObject: payload)
        } catch {
            // Encoding our own body shouldn't fail; treat as a provider-class
            // input problem rather than crashing.
            throw ManagedGenerationError.inputRejected("encode_failed")
        }
    }

    // MARK: - Parse

    /// Maps a `(data, status)` from `/generate` to a result or a typed error.
    /// `401` is handled by the caller (refresh+retry) and never reaches here as
    /// a terminal state.
    static func parse(data: Data, status: Int) throws -> ManagedGenerationResult {
        switch status {
        case 200...299:
            let decoded: GenerateResponseDTO
            do {
                decoded = try JSONDecoder().decode(GenerateResponseDTO.self, from: data)
            } catch {
                throw ManagedGenerationError.malformedResponse
            }
            guard !decoded.prompt.isEmpty else {
                throw ManagedGenerationError.malformedResponse
            }
            let usage = TokenUsage(
                inputTokens: decoded.usage?.inputTokens ?? 0,
                outputTokens: decoded.usage?.outputTokens ?? 0,
                model: decoded.usage?.model ?? "managed"
            )
            return ManagedGenerationResult(
                result: PromptGenerationResult(prompt: decoded.prompt, usage: usage),
                creditsRemaining: decoded.creditsRemaining
            )
        case 402:
            throw ManagedGenerationError.outOfCredits
        case 403, 404:
            throw ManagedGenerationError.notEntitled
        case 401:
            throw ManagedGenerationError.authFailed
        case 429:
            throw ManagedGenerationError.rateLimited
        case 400, 413, 415:
            let reason = String(data: data, encoding: .utf8) ?? "input_rejected"
            throw ManagedGenerationError.inputRejected(reason)
        case 500...599:
            throw ManagedGenerationError.providerUnavailable
        default:
            throw ManagedGenerationError.providerUnavailable
        }
    }
}
