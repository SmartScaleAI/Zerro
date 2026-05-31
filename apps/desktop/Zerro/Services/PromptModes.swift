//
//  PromptModes.swift
//  Zerro
//
//  Created by Colin Breeding on 5/31/26.
//
//  Phase 17 — the per-mode system-prompt layers (Layer 2 of the prompt
//  system). The base layer in `PromptGenerationSystemPrompt` is shared
//  across modes; exactly one of these is appended at generation time per
//  `PromptGenerationSystemPrompt.composed(for:)`:
//
//      system = BASE + "\n\n" + PromptModes.layer(for: mode)
//
//  Like the base, these strings are locked product IP lifted verbatim
//  from `zerro-prompt-system.md` (Layer 2a / 2b). The md hard-wraps each
//  paragraph for readability; this file reflows the prose into flowing
//  single-line paragraphs to match how the base layer was lifted in
//  Phase 9 — the wording is unchanged, only the cosmetic line breaks
//  inside paragraphs are. Structural newlines (the "Structure:" lists)
//  are preserved.
//
//  Change discipline matches the base prompt: tuning these is a product
//  decision, not an implementation one. Edits should be intentional and
//  dated, with the before/after impact on a real recording captured in
//  the commit.
//

import Foundation

enum PromptModes {

    /// The mode layer appended after the base for the given output mode.
    static func layer(for mode: OutputMode) -> String {
        switch mode {
        case .instruct: return instruct
        case .explain:  return explain
        }
    }

    // MARK: - Layer 2a — Instruct mode

    static let instruct: String = """
    TASK: Rewrite the user's spoken request as a clear, structured instruction addressed to an AI coding/assistant agent that will carry it out.

    Write in second person ("you"), imperative and specific. The agent did NOT see the recording — translate everything the user showed or referenced into explicit description the agent can act on without the visuals.

    Use the frames to extract the concrete specifics the agent needs: exact labels, filenames, function names, endpoints, values, and UI element names. Pull these in so the agent is not guessing. When the user refers to something vaguely ("this", "here", "that thing"), resolve it against the frames and state it plainly.

    When the user describes an outcome without naming the exact technical mechanism, express the requirement at the level of intent the agent can implement, rather than inventing a specific implementation detail the user did not state. If a requirement is genuinely ambiguous and the frames do not resolve it, surface it as a brief open question rather than guessing.

    Structure:
    - Lead with a one-sentence summary of the goal.
    - Then the specific requirements as a tight list, in execution order.
    - Include the concrete details pulled from the frames.
    - End with any constraints or "do not" conditions the user stated.

    Keep it lean. Do not pad with explanation of why — the agent needs what to do. Drop the user's emotional framing and asides; keep only what is actionable.
    """

    // MARK: - Layer 2b — Explain mode

    static let explain: String = """
    TASK: Produce a clear explanation of what the user is showing, for a reader who has not seen the recording.

    Write in third person, descriptive and neutral. Describe what the thing is, what it does, and how its parts relate, based on what is visible in the frames and what the user narrates.

    Use the frames to reconstruct structure and sequence for the reader: what the components are, how they relate, and the order in which things happen across the recording. Favor a coherent picture of the whole over isolated details.

    The user may phrase things as requests or intentions ("I want to fix this", "make it do X"). Do not turn these into instructions. Instead, translate them into described characteristics of the subject. For example, if the user says they want to fix fragile error handling, the explanation may note that the error handling is currently fragile — as an observed property, not a task. Surface what the user verbally emphasized as notable, framed descriptively.

    Structure:
    - Open with a one-sentence "what this is."
    - Then explain the key components or behavior in plain language.
    - Include any characteristic the user clearly treated as important.

    Do not give instructions or next steps unless the user explicitly asked. This is an explanation, not a task.
    """
}
