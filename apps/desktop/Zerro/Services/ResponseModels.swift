//
//  ResponseModels.swift
//  Zerro
//
//  Created by Colin Breeding on 6/11/26.
//
//  Phase 2 of the modes → typed-output refactor
//  (docs/refactor-artifact-response-plan.md): the data model for a parsed
//  model response — chat text plus at most one typed output. ADDITIVE in
//  this phase: nothing constructs these yet; Phase 4 wires OutputParser
//  into the generation paths and Phase 5 renders them.
//
//  The per-type UI table in plan §2 is the SINGLE SOURCE OF TRUTH for the
//  property values on OutputType. If the table changes, this enum changes
//  with it — nothing else in the app may hardcode a button label, icon, or
//  copy rule per type.
//

import Foundation

// MARK: - OutputType

/// The five output types of the §2 output contract. Raw values are the
/// exact wire strings the model emits in the fence's `type="…"` attribute.
///
/// §2 per-type UI table (source of truth; revised 2026-06-12 — copy is
/// body-only for EVERY type, context is internal-only):
///
///     | type         | Button label | Icon     | Body rendering        | Copy payload     |
///     | agent_prompt | Copy Prompt  | {}       | markdown, mono-leaning| body only        |
///     | message      | Copy draft   | envelope | prose                 | body only        |
///     | snippet      | Copy snippet | chevron  | monospace code        | body only (exact)|
///     | document     | Copy text    | doc      | prose                 | body only        |
///     | generic      | Copy         | doc      | markdown              | body only        |
enum OutputType: String, Codable, CaseIterable, Equatable, Sendable {
    case agentPrompt = "agent_prompt"
    case message
    case snippet
    case document
    case generic

    /// Primary copy-button label on the output card (and history rows).
    var buttonLabel: String {
        switch self {
        case .agentPrompt: "Copy Prompt"
        case .message: "Copy draft"
        case .snippet: "Copy snippet"
        case .document: "Copy text"
        case .generic: "Copy"
        }
    }

    /// SF Symbol for the card header / history row. The §2 table names the
    /// glyphs generically ({} / envelope / chevron / doc); these are their
    /// SF Symbols equivalents.
    var iconName: String {
        switch self {
        case .agentPrompt: "curlybraces"
        case .message: "envelope"
        case .snippet: "chevron.left.forwardslash.chevron.right"
        case .document, .generic: "doc.text"
        }
    }

    /// Whether the card body renders in a monospace font. Only `snippet` is
    /// fully monospace; `agent_prompt` is "markdown, mono-leaning" in the §2
    /// table — that is a Phase 5 styling nuance inside markdown rendering,
    /// not a monospace body.
    var rendersMonospace: Bool {
        self == .snippet
    }
}

// MARK: - GeneratedOutput

/// One parsed output block. `type` is post-coercion (an unknown wire type
/// becomes `.generic` per §2); `rawType` preserves what the model actually
/// emitted so logging/eval can see the difference. `title` is the
/// model-written card header (contract caps it at 80 chars — over-length is
/// a parser warning, not a failure).
struct GeneratedOutput: Equatable, Sendable {
    let type: OutputType
    let rawType: String
    let title: String
    let body: String
}

// MARK: - ParsedResponse

/// The result of running `OutputParser` over a raw model response.
///
/// Fail-safe by construction: `chatText` is ALWAYS renderable — on any
/// malformed input it carries the entire raw output and `output` is nil
/// (`isValid` false records that the fallback fired). `wasRecovered` is true
/// when the §2 recovery tier (R1/R2/R3) rescued a malformed fence; recovered
/// responses are valid, but the flag is surfaced so recovery rate stays
/// observable (the same discipline as the eval scorecard's fifth metric).
struct ParsedResponse: Equatable, Sendable {
    let chatText: String
    let output: GeneratedOutput?
    /// False when the fail-safe fallback fired (whole output became chat).
    let isValid: Bool
    /// True when any recovery-tier rule (R1/R2/R3) was used to parse.
    let wasRecovered: Bool
    /// Human-readable parse notes (unknown type coerced, recovery rule
    /// fired, over-long title, …) — for logging, never for UI.
    let warnings: [String]
    /// False ONLY when the generation step signalled the empty case via the
    /// `<<<ZERRO_NO_REQUEST>>>` sentinel — the recording held no request of
    /// any kind. Defaults true for every other path (valid output,
    /// category-2 explain/advice, and the malformed-response fail-safe). Parsed
    /// and retained for logging/diagnostics; no behaviour currently keys off it
    /// since the "Write agent prompt" affordance was removed.
    let requestPresent: Bool

    /// Mirrors the synthesized memberwise init but defaults `requestPresent`
    /// to true, so the existing construction sites compile unchanged and only
    /// the parser's no-request path passes false.
    init(
        chatText: String,
        output: GeneratedOutput?,
        isValid: Bool,
        wasRecovered: Bool,
        warnings: [String],
        requestPresent: Bool = true
    ) {
        self.chatText = chatText
        self.output = output
        self.isValid = isValid
        self.wasRecovered = wasRecovered
        self.warnings = warnings
        self.requestPresent = requestPresent
    }
}
