//
//  PromptGenerationService.swift
//  Zerro
//
//  Created by Colin Breeding on 5/28/26.
//
//  Provider-neutral protocol for the Phase 9 prompt-generation step.
//  Phase 9 v1 concrete impl is `OpenAIPromptGenerationService` (GPT-4o
//  multimodal). Future providers (Anthropic / Gemini / local) implement
//  this same shape — AppState's orchestration doesn't change when we
//  swap.
//
//  The `systemPrompt` is passed at call time rather than read from the
//  constant inside the impl so the wire test layer / future
//  experimentation can swap prompts without touching provider code.
//  Production call sites should always pass the value from
//  `PromptGenerationSystemPrompt.composed(for:)` verbatim (Phase 17: base
//  layer + the effective output mode's layer).
//

import Foundation

protocol PromptGenerationService: Sendable {
    /// Generates a structured Markdown prompt from `timeline`. The
    /// impl is responsible for resolving each frame's local image URL
    /// into the provider's image-content format (e.g. base64 data URL
    /// for OpenAI), at request-build time — TimelineItem.frame carries
    /// the URL, not the bytes, to keep the in-memory timeline small.
    func generatePrompt(
        timeline: InterleavedTimeline,
        systemPrompt: String
    ) async throws -> PromptGenerationResult
}

// MARK: - PromptGenerationResult

struct PromptGenerationResult: Sendable {
    /// Raw Markdown returned by the model. The orchestrator copies
    /// this verbatim to the clipboard — no post-processing, no
    /// stripping. The system prompt's "Rules" section is what keeps
    /// the output clean.
    let prompt: String

    /// Token counts + model id, used for the cost log line. Provider-
    /// neutral so a future Anthropic impl can fill in its own input/
    /// output counts the same way.
    let usage: TokenUsage
}

// MARK: - TokenUsage

struct TokenUsage: Sendable {
    let inputTokens: Int
    let outputTokens: Int
    /// Model id exactly as reported by the provider (e.g. the dated
    /// alias `gpt-4o-2024-08-06` rather than the rolling `gpt-4o`).
    /// Logged for cost attribution + retroactive analysis when pricing
    /// changes.
    let model: String
}

// MARK: - PromptGenerationError

/// Known failure shapes. Phase 9 Step 5 maps these to
/// RecordingFailureReason cases (apiKeyMissing, apiAuth, networkOffline,
/// rateLimited, providerError). The associated values are for logging,
/// never user-visible.
enum PromptGenerationError: Error {
    case missingAPIKey
    case auth
    case rateLimited
    case network(underlying: Error)
    /// Non-2xx provider response. Carries the status code ONLY — useful and
    /// non-sensitive. The raw response body is deliberately NOT an associated
    /// value: this error can reach `CrashReporting.capture`, where the PostHog error tracker
    /// SDK derives the exception value from the error's description, and a raw
    /// provider body would ride into that value scrubbed only by a length clamp
    /// (not a content filter). The body is logged `.private` at the throw site
    /// for local debugging instead. See `OpenAIPromptGenerationService`.
    case server(status: Int)
    case decodeFailure(underlying: Error)
    /// Provider returned a valid response but with no text content
    /// (e.g. `choices[0].message.content` was null or empty). Distinct
    /// from `server` because it's the model's choice, not an outage.
    case emptyContent
    /// The generation hit the provider's output-token limit and was cut off
    /// before completing (`stop_reason == "max_tokens"` for Anthropic,
    /// `finishReason == "MAX_TOKENS"` for Gemini, `finish_reason == "length"`
    /// for OpenAI). The partial text is NOT usable — it can contain an
    /// unterminated `<<<ZERRO_ARTIFACT` fence that would otherwise leak into the
    /// pill as raw wire syntax (handoff-artifact-fence-leak). Surfaced as a
    /// distinct failure so a cut-off response is never handed to the parser as a
    /// clean success.
    case truncated
}
