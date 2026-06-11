//
//  ModelRegistry.swift
//  Zerro
//
//  Phase 6 (multi-model plan 6A/6B) — the app-side model registry.
//
//  ⚠️ THIRD MIRROR — KEEP IN SYNC. This table intentionally duplicates:
//    1. supabase/functions/generate/models.ts   (the server source of truth:
//       request validation + per-model credit charge)
//    2. apps/desktop/Scripts/eval-models.mjs    (the eval harness)
//  Any change to the model list, credit prices, or the recommended default
//  must land in all three places (F8-style contract; the server file carries
//  the same note). The ids are the exact wire values `/generate` validates
//  against ALLOWED_MODELS — a drifted id here means 400s for users.
//
//  CALIBRATION CAVEAT (plan §2): creditPrice values are calibration v1 from
//  June-2026 published rates; the server retunes post-launch and this mirror
//  follows. Prices here are DISPLAY data (picker rows, "~N left") — the
//  authoritative charge is the server's, returned as `credits_charged`.
//
//  `enabled` mirrors the server's kill switch. The picker only renders
//  enabled entries; a model disabled server-side after this build ships
//  would 400, so flipping it here too (next release) keeps the UI honest.
//

import Foundation

// MARK: - ModelProvider

/// Which API vendor serves a model. In Managed mode this is invisible plumbing
/// (the server routes); in BYOK mode it selects the user's per-provider key
/// (Phase 6C) and gates selectability.
enum ModelProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case openai
    case gemini
    case anthropic

    /// User-facing vendor name (BYOK key fields, picker hints).
    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .anthropic: return "Anthropic"
        }
    }
}

// MARK: - ModelEntry

/// One selectable model — mirrors the server's `ModelEntry` field-for-field.
struct ModelEntry: Equatable, Identifiable, Sendable {
    /// The exact wire value sent as `model` in the `/generate` body (and the
    /// provider API model id the BYOK path calls directly).
    let id: String
    let provider: ModelProvider
    /// User-facing name in the picker.
    let displayName: String
    /// Compact name for tight surfaces (the "≈ N with Flash · M with Opus"
    /// translation line, §1.5). App-side display only — NOT part of the
    /// server-mirror contract.
    let shortName: String
    /// Fixed credits charged per generation (1 credit = $0.01). Display-only
    /// on the client; the server's charge is authoritative.
    let creditPrice: Int
    /// The picker's "Recommended for Zerro" badge (exactly one model).
    let recommended: Bool
    /// Mirrors the server kill switch — disabled entries never render.
    let enabled: Bool

    init(
        id: String,
        provider: ModelProvider,
        displayName: String,
        shortName: String,
        creditPrice: Int,
        recommended: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.shortName = shortName
        self.creditPrice = creditPrice
        self.recommended = recommended
        self.enabled = enabled
    }
}

// MARK: - ModelRegistry

/// Namespace for the registry table + lookups. Pure value data — no I/O, no
/// persistence (the user's selection lives in `PreferencesStore`).
enum ModelRegistry {

    /// Ordered by creditPrice ascending — the picker renders cheapest-first
    /// (plan 6A): the product labels models by cost, not quality.
    static let all: [ModelEntry] = [
        ModelEntry(id: "gpt-5.4-mini", provider: .openai, displayName: "GPT-5.4 mini", shortName: "GPT mini", creditPrice: 2),
        ModelEntry(id: "gemini-3.5-flash", provider: .gemini, displayName: "Gemini 3.5 Flash", shortName: "Flash", creditPrice: 4, recommended: true),
        ModelEntry(id: "gemini-3.1-pro-preview", provider: .gemini, displayName: "Gemini 3.1 Pro", shortName: "Gemini Pro", creditPrice: 5),
        ModelEntry(id: "claude-sonnet-4-6", provider: .anthropic, displayName: "Claude Sonnet 4.6", shortName: "Sonnet", creditPrice: 7),
        ModelEntry(id: "claude-opus-4-7", provider: .anthropic, displayName: "Claude Opus 4.7", shortName: "Opus", creditPrice: 10),
        ModelEntry(id: "gpt-5.5", provider: .openai, displayName: "GPT-5.5", shortName: "GPT-5.5", creditPrice: 11),
    ]

    /// What the picker renders (mirrors the server's ALLOWED_MODELS gate).
    static let enabled: [ModelEntry] = all.filter(\.enabled)

    /// Registry lookup by wire id (enabled or not — disabled entries stay
    /// resolvable for displaying historic results, same as the server).
    static func entry(id: String) -> ModelEntry? {
        all.first { $0.id == id }
    }

    /// The default selection: the recommended enabled entry, falling back to
    /// the cheapest enabled one if the recommendation is ever kill-switched —
    /// the same resolution rule as the server's DEFAULT_MODEL_ID, so a fresh
    /// install and an un-updated app (which sends no `model`) get the same
    /// model.
    static let defaultModelID: String =
        (all.first { $0.recommended && $0.enabled } ?? enabled[0]).id
}
