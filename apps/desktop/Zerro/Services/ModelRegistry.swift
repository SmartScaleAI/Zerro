//
//  ModelRegistry.swift
//  Zerro
//
//  Phase 6 (multi-model plan 6A/6B) — the app-side model registry.
//
//  ⚠️ THIRD MIRROR — KEEP IN SYNC. This table intentionally duplicates:
//    1. supabase/functions/generate/models.ts   (the server source of truth:
//       request validation + the per-model fallback estimate; the charge
//       itself is metered on real cost)
//    2. apps/desktop/Scripts/eval-models.mjs    (the eval harness)
//  Any change to the model list or the recommended default must land in all
//  three places (F8-style contract; the server file carries the same note).
//  The ids are the exact wire values `/generate` validates against
//  ALLOWED_MODELS — a drifted id here means 400s for users.
//
//  APP-SIDE MIRROR CONTRACT (metered-credits Phase 4): the app no longer
//  charges or displays any per-model cost, so it INTENTIONALLY OMITS the
//  server's charge field (`fallbackCredits`, formerly the app's `creditPrice`)
//  and the display-only `shortName`. The app-side mirror is now exactly
//  id / provider / displayName / recommended / enabled. Charging is metered on
//  the server; the only per-recording number the user sees is the actual
//  `credits_charged` the server returns post-generation.
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

/// One selectable model. Mirrors the server's `ModelEntry` for the fields the
/// app needs — id/provider/displayName/recommended/enabled. The server's
/// per-model charge field (`fallbackCredits`) is deliberately NOT mirrored: the
/// app shows no per-model cost (metered-credits Phase 4).
struct ModelEntry: Equatable, Identifiable, Sendable {
    /// The exact wire value sent as `model` in the `/generate` body (and the
    /// provider API model id the BYOK path calls directly).
    let id: String
    let provider: ModelProvider
    /// User-facing name in the picker.
    let displayName: String
    /// The picker's "Recommended for Zerro" badge (exactly one model).
    let recommended: Bool
    /// Mirrors the server kill switch — disabled entries never render.
    let enabled: Bool

    init(
        id: String,
        provider: ModelProvider,
        displayName: String,
        recommended: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.recommended = recommended
        self.enabled = enabled
    }
}

// MARK: - ModelRegistry

/// Namespace for the registry table + lookups. Pure value data — no I/O, no
/// persistence (the user's selection lives in `PreferencesStore`).
enum ModelRegistry {

    /// Registry order mirrors the server's (the historical cheapest-first
    /// ordering, plan 6A). The app shows no per-model cost, so this is just the
    /// stable render order; ids/order stay in lockstep with models.ts.
    static let all: [ModelEntry] = [
        ModelEntry(id: "gpt-5.4-mini", provider: .openai, displayName: "GPT-5.4 mini"),
        ModelEntry(id: "gemini-3.5-flash", provider: .gemini, displayName: "Gemini 3.5 Flash", recommended: true),
        ModelEntry(id: "gemini-3.1-pro-preview", provider: .gemini, displayName: "Gemini 3.1 Pro"),
        ModelEntry(id: "claude-sonnet-4-6", provider: .anthropic, displayName: "Claude Sonnet 4.6"),
        ModelEntry(id: "claude-opus-4-7", provider: .anthropic, displayName: "Claude Opus 4.7"),
        ModelEntry(id: "gpt-5.5", provider: .openai, displayName: "GPT-5.5"),
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
