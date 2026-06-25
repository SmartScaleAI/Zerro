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
//  AUDIO + FRAMES to the Supabase `generate` proxy and gets the finished
//  result back. The server owns transcription and the system prompt (§6.1) —
//  so this client sends NEITHER a transcript NOR a prompt; that is the
//  control that stops a paying user repurposing the Zerro provider keys as a
//  general LLM (§14.1). Typed-artifact refactor: the v1 `mode` enum is gone —
//  the client supplies NOTHING that steers the (server-owned) prompt.
//
//  Wire shape (matches `supabase/functions/generate/limits.ts`):
//    POST /generate   Authorization: Bearer <session token>
//    {
//      "model": "gemini-3.5-flash",        // multi-model 6B: a ModelRegistry id
//      "has_speech": true,                 // Phase 6: false → server skips Whisper
//      "audio":  { "mime": "audio/m4a", "filename": "recording.m4a",
//                  "data": "<base64>", "duration_seconds": 42.0 },
//      "frames": [ { "timestamp": 0.0, "mime": "image/jpeg", "data": "<base64>" }, … ]
//    }
//  Response (200): { "prompt": "...", "usage": { input_tokens, output_tokens, model },
//                    "credits_remaining": N, "credits_charged": N }
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
    /// Carries the HTTP status (always 429 today, kept for symmetry) and a
    /// short, pre-truncated server message so the failure is triageable in
    /// error tracking rather than an opaque `error 0`.
    case rateLimited(status: Int, body: String?)
    /// `401` even AFTER a fresh-token retry — a real auth problem, not a
    /// routine mid-use expiry (those are refreshed transparently).
    case authFailed
    /// `413`/`415`/`400` — the server-side input fuse rejected the payload. A
    /// real recording can't trip this; treated as a provider-class error.
    case inputRejected(String)
    /// `502`/`503`/`5xx` — the proxy or OpenAI is unavailable. Retryable.
    /// Carries the HTTP status (e.g. 502/503) and a short, pre-truncated
    /// server message so a provider outage is triageable in error tracking
    /// (grouped by reason+status) instead of an opaque `error 0`.
    case providerUnavailable(status: Int, body: String?)
    /// `422` — the server's chat completed but was cut off at the output-token
    /// limit (`stop_reason`/`finishReason`/`finish_reason` truncation). The
    /// server withholds the half-formed prompt rather than returning a partial
    /// (possibly fence-leaking) result; surfaced distinctly so the app can show
    /// a clear "too long" state instead of a generic provider error
    /// (handoff-artifact-fence-leak).
    case responseTruncated
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
    /// `credits_charged` from the server (multi-model D2) — the exact spend
    /// for the "−N credits" toast. `nil` from a pre-D2 backend.
    let creditsCharged: Int?
    /// Phase 2 (Dev Mode call 2) — the structured per-reference anchors the
    /// server parsed out of the model's `zerro_anchors` block (the M7 contract,
    /// the SAME shape BYOK's local `DevAnchorParser.parse` produces). Empty on
    /// the normal path (the server omits the `anchors` field) and on a server too
    /// old to return it — the dev caller then falls back to parsing the prompt.
    let modelAnchors: [DevAnchor]

    init(
        result: PromptGenerationResult,
        creditsRemaining: Int?,
        creditsCharged: Int?,
        modelAnchors: [DevAnchor] = []
    ) {
        self.result = result
        self.creditsRemaining = creditsRemaining
        self.creditsCharged = creditsCharged
        self.modelAnchors = modelAnchors
    }
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

    /// Runs a proxy generation: reads the audio + frames off disk, base64s
    /// them, POSTs to `/generate` with a bearer token, and parses the
    /// returned prompt. A `401` triggers exactly one transparent token refresh +
    /// retry. Throws `ManagedGenerationError` on every failure path.
    ///
    /// `tokenProvider` selects the credential: the default Managed
    /// `SessionTokenManager` (a subscription token) or — passed by the trial
    /// path (Phase F) — a `TrialCreditsManager` (a trial token). The wire shape,
    /// flow, and error mapping are identical; only the token's `kind` differs,
    /// which the SERVER uses to pick the credit ledger.
    /// `idempotencyKey` (M1): one key per recording, reused across EVERY retry of
    /// that recording (the 401 refresh-retry below, and AppState's user-driven
    /// `retryFailedPrompt`). It rides as the `Idempotency-Key` header so the
    /// server replays a charged-but-dropped result instead of charging twice.
    /// Defaulted to a fresh UUID so callers that don't care (tests, ad-hoc calls)
    /// still get a valid single-use key; the real path passes the recording's
    /// stable `ProcessedRecording.idempotencyKey`.
    /// `model` (Phase 6 / multi-model): the registry wire id the server
    /// validates against ALLOWED_MODELS and routes to the provider adapter.
    /// Charging is metered on the real cost, not a per-model price. Defaults to
    /// the recommended model — the same model the server resolves when the field
    /// is absent (D1), so the default is a no-op for older test fixtures.
    func generate(
        audioURL: URL,
        frames: [ExtractedFrame],
        durationSeconds: Double?,
        clicks: [ResolvedClick] = [],
        hasSpeech: Bool = true,
        model: String = ModelRegistry.defaultModelID,
        // Phase 2 (Dev Mode): `"dev"` selects the server's repo-scoped dev prompt
        // (Goal/Changes/Scope). nil → the normal v2 prompt. A SELECTOR only — the
        // client never supplies prompt content.
        mode: String? = nil,
        tokenProvider: ProxyTokenProviding? = nil,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> ManagedGenerationResult {
        let provider: ProxyTokenProviding = tokenProvider ?? sessionTokens
        // Flatten the frames to a Sendable representation on the current actor,
        // then build the (key-free) request body OFF the main actor — reading
        // and base64-ing a multi-MB audio + frame payload would otherwise hitch
        // the UI (the BYOK `OpenAIPromptGenerationService.encodeBody` encodes
        // off-main the same way). The same bytes are reused on the post-refresh
        // retry. Clicks are already-Sendable value types, passed straight in.
        let uploads = frames.map { FrameUpload(url: $0.url, timestamp: CMTimeGetSeconds($0.timestamp), ocrText: $0.ocrText) }
        let body = try await Task.detached(priority: .userInitiated) {
            try Self.encodeBody(
                audioURL: audioURL,
                frames: uploads,
                durationSeconds: durationSeconds,
                clicks: clicks,
                hasSpeech: hasSpeech,
                model: model,
                mode: mode
            )
        }.value

        // First attempt with the cached/fresh token. The same idempotency key
        // rides both this attempt and the post-refresh retry below — the server
        // dedupes on it, so a refresh-retry can't double-charge.
        let token = try await token(from: provider)
        var (data, status) = try await post(body: body, token: token, idempotencyKey: idempotencyKey)

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
            (data, status) = try await post(body: body, token: refreshed, idempotencyKey: idempotencyKey)
            if status == 401 { throw ManagedGenerationError.authFailed }
        }

        return try Self.parse(data: data, status: status)
    }

    // MARK: - Dev Mode 2-call flow (Phase 2 — managed/trial hover-deixis)

    /// A flattened, Sendable transcript the dev call-2 (`generateDev`) ships in
    /// place of the audio: the segment-level speech the server interleaves, plus
    /// the measured duration (for the STT-cost meter + the seconds gate). Built
    /// from the call-1 `Transcript` on the main actor, then encoded off it.
    struct DevTranscriptUpload: Sendable {
        struct Segment: Sendable {
            let start: Double
            let end: Double
            let text: String
        }
        let segments: [Segment]
        /// The recording's duration in seconds (call 1's measured length), so the
        /// server can meter STT cost + run the true-seconds gate WITHOUT the audio.
        let durationSeconds: Double?
    }

    /// Dev Mode CALL 1 (Phase 2 §7) — the FREE word-level transcription. POSTs
    /// `{mode:"dev-transcribe", audio, has_speech}` and parses the returned
    /// word-level transcript. The server charges nothing, takes no concurrency
    /// slot, and writes no idempotency entry for this call (it is auth-gated +
    /// rate-limited only). The client resolves deixis anchors against this exact
    /// transcript before the billable call 2. Token handling mirrors `generate`:
    /// one transparent refresh on 401, then `authFailed`.
    func devTranscribe(
        audioURL: URL,
        durationSeconds: Double?,
        hasSpeech: Bool = true,
        tokenProvider: ProxyTokenProviding? = nil,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> Transcript {
        let provider: ProxyTokenProviding = tokenProvider ?? sessionTokens
        // Read + base64 the audio off the main actor (multi-MB), exactly like
        // `generate`. The same bytes are reused on the post-refresh retry.
        let body = try await Task.detached(priority: .userInitiated) {
            try Self.encodeTranscribeBody(
                audioURL: audioURL,
                durationSeconds: durationSeconds,
                hasSpeech: hasSpeech
            )
        }.value

        let token = try await token(from: provider)
        var (data, status) = try await post(body: body, token: token, idempotencyKey: idempotencyKey)
        if status == 401 {
            Log.billing.notice("dev-transcribe 401 — refreshing token and retrying once")
            let refreshed: String
            do {
                refreshed = try await provider.refreshToken()
            } catch {
                throw ManagedGenerationError.authFailed
            }
            (data, status) = try await post(body: body, token: refreshed, idempotencyKey: idempotencyKey)
            if status == 401 { throw ManagedGenerationError.authFailed }
        }
        return try Self.parseTranscribe(data: data, status: status)
    }

    /// Dev Mode CALL 2 (Phase 2 §7) — the enriched, billable generation. Sends
    /// `{mode:"dev"}` with the PRE-SUPPLIED transcript (so the server skips re-STT
    /// — no double STT round-trip / charge), the recording frames PLUS the marked
    /// `DEIXIS REFERENCE` anchor crops (the caller concatenates them), and the
    /// clicks — but NO audio (it rode in call 1). Returns the `agent_prompt`
    /// (parsed exactly like `generate`) plus the structured `modelAnchors`. Token
    /// + idempotency handling mirror `generate` (the credit is consumed once here).
    func generateDev(
        frames: [ExtractedFrame],
        transcript: DevTranscriptUpload,
        clicks: [ResolvedClick] = [],
        hasSpeech: Bool = true,
        model: String = ModelRegistry.defaultModelID,
        tokenProvider: ProxyTokenProviding? = nil,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> ManagedGenerationResult {
        let provider: ProxyTokenProviding = tokenProvider ?? sessionTokens
        let uploads = frames.map { FrameUpload(url: $0.url, timestamp: CMTimeGetSeconds($0.timestamp), ocrText: $0.ocrText) }
        let body = try await Task.detached(priority: .userInitiated) {
            try Self.encodeDevBody(
                frames: uploads,
                transcript: transcript,
                clicks: clicks,
                hasSpeech: hasSpeech,
                model: model
            )
        }.value

        let token = try await token(from: provider)
        var (data, status) = try await post(body: body, token: token, idempotencyKey: idempotencyKey)
        if status == 401 {
            Log.billing.notice("dev generate 401 — refreshing token and retrying once")
            let refreshed: String
            do {
                refreshed = try await provider.refreshToken()
            } catch {
                throw ManagedGenerationError.authFailed
            }
            (data, status) = try await post(body: body, token: refreshed, idempotencyKey: idempotencyKey)
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
            // Session-mint 429 — no response body is surfaced at this layer.
            throw ManagedGenerationError.rateLimited(status: 429, body: nil)
        } catch {
            throw ManagedGenerationError.authFailed
        }
    }

    // MARK: - POST

    private func post(
        body: Data,
        token: String,
        idempotencyKey: String,
        url: URL = ManagedBackend.generateURL
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
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
        /// Phase 3 — the frame's redacted on-device-OCR text (secrets already
        /// masked client-side). Sent as `ocr_text`; the server trusts it as
        /// already-redacted and only length-caps it defensively.
        let ocrText: String?
    }

    /// Builds the `/generate` JSON body. Audio + each frame are read off disk
    /// and base64-encoded here, at request-build time — the 33% overhead is
    /// dropped after the request, never held on the in-memory timeline (mirrors
    /// the BYOK `base64DataURL` discipline). `nonisolated` so it runs in a
    /// detached task off the main actor.
    nonisolated static func encodeBody(
        audioURL: URL,
        frames: [FrameUpload],
        durationSeconds: Double?,
        clicks: [ResolvedClick] = [],
        hasSpeech: Bool = true,
        model: String = ModelRegistry.defaultModelID,
        mode: String? = nil
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
                // Phase 3: the frame's redacted OCR text ("" when none). The
                // server parses `ocr_text` defensively (length-capped) and
                // interleaves it after the image; secrets are already masked here.
                "ocr_text": frame.ocrText ?? "",
            ])
        }

        // Phase 4: the resolved clicks (timestamp + on-screen label). The label
        // came from the client's OCR, already redaction-safe; the server
        // defensively caps the count + label length and interleaves them as
        // `clicked "<label>"` lines. Empty array when nothing was clicked.
        let clickObjects: [[String: Any]] = clicks.map {
            ["timestamp": $0.seconds, "label": $0.label]
        }

        // Typed-artifact refactor: NO field steers the server-owned prompt —
        // no mode, no transcript, no system prompt (§6.1). Phase 6:
        // `has_speech` is a cost hint, not prompt input — `false` tells the
        // server to skip the Whisper call (empty segments). `model`
        // (multi-model 6B) selects the provider adapter server-side (charging
        // is metered on real cost) — never the prompt (Appendix C #3).
        var payload: [String: Any] = [
            "model": model,
            "audio": audio,
            "frames": frameObjects,
            "clicks": clickObjects,
            "has_speech": hasSpeech,
        ]
        // Phase 2 (Dev Mode): the prompt SELECTOR. Only sent when set, so a
        // normal recording's body is byte-identical to before.
        if let mode { payload["mode"] = mode }

        do {
            return try JSONSerialization.data(withJSONObject: payload)
        } catch {
            // Encoding our own body shouldn't fail; treat as a provider-class
            // input problem rather than crashing.
            throw ManagedGenerationError.inputRejected("encode_failed")
        }
    }

    /// Builds the Dev Mode CALL 1 body: `{mode:"dev_transcribe", audio, has_speech}`.
    /// Audio ONLY — no frames, no model — the server returns a word-level
    /// transcript (free). `nonisolated` so it runs off the main actor (the audio
    /// read + base64 is multi-MB).
    nonisolated static func encodeTranscribeBody(
        audioURL: URL,
        durationSeconds: Double?,
        hasSpeech: Bool
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

        // The server keys on this EXACT string (`dev_transcribe`, underscore) to
        // route to the free, slot-free word-level transcription path.
        let payload: [String: Any] = [
            "mode": "dev_transcribe",
            "audio": audio,
            "has_speech": hasSpeech,
        ]
        do {
            return try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw ManagedGenerationError.inputRejected("encode_failed")
        }
    }

    /// Builds the Dev Mode CALL 2 body: `{mode:"dev", model, frames, clicks,
    /// has_speech, transcript}` — the enriched generation. NO `audio` (it rode in
    /// call 1); the `transcript` (segments + duration) makes the server skip
    /// re-STT, and the `frames` array carries the recording frames PLUS the marked
    /// `DEIXIS REFERENCE` anchor crops (their hint rides as each frame's
    /// `ocr_text`). `nonisolated` so the frame reads + base64 run off the main actor.
    nonisolated static func encodeDevBody(
        frames: [FrameUpload],
        transcript: DevTranscriptUpload,
        clicks: [ResolvedClick] = [],
        hasSpeech: Bool = true,
        model: String = ModelRegistry.defaultModelID
    ) throws -> Data {
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
                "ocr_text": frame.ocrText ?? "",
            ])
        }

        let clickObjects: [[String: Any]] = clicks.map {
            ["timestamp": $0.seconds, "label": $0.label]
        }

        let segmentObjects: [[String: Any]] = transcript.segments.map {
            ["start": $0.start, "end": $0.end, "text": $0.text]
        }
        var transcriptPayload: [String: Any] = ["segments": segmentObjects]
        if let d = transcript.durationSeconds, d.isFinite, d >= 0 {
            transcriptPayload["duration_seconds"] = d
        }

        let payload: [String: Any] = [
            "model": model,
            "mode": "dev",
            "frames": frameObjects,
            "clicks": clickObjects,
            "has_speech": hasSpeech,
            "transcript": transcriptPayload,
        ]
        do {
            return try JSONSerialization.data(withJSONObject: payload)
        } catch {
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
            // Phase 2 (Dev Mode call 2): the server returns the structured
            // per-reference anchors it parsed from the model's `zerro_anchors`
            // block. Absent on the normal path (no `anchors` key) → []. Parsed
            // through the SAME lenient `DevAnchorParser` the BYOK path uses, so an
            // unknown/malformed shape degrades to [] rather than crashing.
            var modelAnchors: [DevAnchor] = []
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let anchorsJSON = obj["anchors"] {
                modelAnchors = DevAnchorParser.parseJSON(anchorsJSON)
            }
            return ManagedGenerationResult(
                result: PromptGenerationResult(prompt: decoded.prompt, usage: usage),
                creditsRemaining: decoded.creditsRemaining,
                creditsCharged: decoded.creditsCharged,
                modelAnchors: modelAnchors
            )
        case 402:
            throw ManagedGenerationError.outOfCredits
        case 403, 404:
            throw ManagedGenerationError.notEntitled
        case 401:
            throw ManagedGenerationError.authFailed
        case 422:
            // Server detected an output-token truncation and withheld the
            // half-formed prompt (handoff-artifact-fence-leak).
            throw ManagedGenerationError.responseTruncated
        case 429:
            throw ManagedGenerationError.rateLimited(status: status, body: Self.shortBody(data))
        case 400, 413, 415:
            let reason = String(data: data, encoding: .utf8) ?? "input_rejected"
            throw ManagedGenerationError.inputRejected(reason)
        case 500...599:
            throw ManagedGenerationError.providerUnavailable(status: status, body: Self.shortBody(data))
        default:
            throw ManagedGenerationError.providerUnavailable(status: status, body: Self.shortBody(data))
        }
    }

    /// Maps a `(data, status)` from the Dev Mode CALL 1 (`dev_transcribe`) to a
    /// `Transcript` or a typed error. Same status taxonomy as `parse` minus the
    /// usage/credit fields — call 1 charges nothing. The 402 case is purely
    /// defensive (the server never charges this path).
    static func parseTranscribe(data: Data, status: Int) throws -> Transcript {
        switch status {
        case 200...299:
            let decoded: TranscribeResponseDTO
            do {
                decoded = try JSONDecoder().decode(TranscribeResponseDTO.self, from: data)
            } catch {
                throw ManagedGenerationError.malformedResponse
            }
            return decoded.transcript.toTranscript()
        case 402:
            throw ManagedGenerationError.outOfCredits // defensive — call 1 never charges
        case 403, 404:
            throw ManagedGenerationError.notEntitled
        case 401:
            throw ManagedGenerationError.authFailed
        case 429:
            throw ManagedGenerationError.rateLimited(status: status, body: Self.shortBody(data))
        case 400, 413, 415:
            let reason = String(data: data, encoding: .utf8) ?? "input_rejected"
            throw ManagedGenerationError.inputRejected(reason)
        default:
            throw ManagedGenerationError.providerUnavailable(status: status, body: Self.shortBody(data))
        }
    }

    /// The server error body, collapsed to a single line and capped at 80 chars
    /// for safe telemetry. ERROR PATH ONLY — this is a transport/server error
    /// message, NEVER transcript or model-response content. Truncating here (at
    /// the throw site, not just at the reporting site) is what keeps the value
    /// within the `CrashReporting` scrubber's 80-char limit. Returns `nil` when
    /// the body is empty.
    private static func shortBody(_ data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // Collapse internal whitespace/newlines so a multi-line body stays a
        // single readable line in the telemetry property.
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(80))
    }
}
