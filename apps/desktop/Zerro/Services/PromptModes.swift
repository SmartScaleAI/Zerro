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
//  2026-06-06 (Phase 5): added the no-request line to `instruct` — when
//  the recording has no actionable request, emit a single plain line
//  saying so instead of inventing a task. EXPLAIN is intentionally
//  unchanged. Mirrored in generate/prompt.ts and Scripts/eval-models.mjs.
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

    Write in second person ("you"), imperative and specific — you are addressing the agent directly. The output is pasted straight into that agent, so phrase everything as direct instructions to it and NEVER refer to "the user", "the recording", "the speaker", or what someone "wants" or "instructed" — say "Rename `handleTap` to `handleSubmit`", not "The user wants `handleTap` renamed". The agent did NOT see the recording, so translate everything shown or referenced into explicit description it can act on without the visuals.

    Use the frames to extract the concrete specifics the agent needs: exact labels, filenames, function names, endpoints, values, and UI element names. Pull these in so the agent is not guessing. When the user refers to something vaguely ("this", "here", "that thing"), resolve it against the frames and state it plainly.

    When the user describes an outcome without naming the exact technical mechanism, express the requirement at the level of intent the agent can implement, rather than inventing a specific implementation detail the user did not state. If a requirement is genuinely ambiguous and the frames do not resolve it, surface it as a brief open question rather than guessing. If the narration points out a problem or error without explicitly asking for a fix, capture it as the issue to address — describe the problem precisely, but don't invent a specific solution that wasn't indicated.

    Structure:
    - Lead with a one-sentence summary of the goal.
    - Then the specific requirements as a tight, ordered list. If the recording contains several distinct requests, give each its own item (or short section) so none is blended together or dropped.
    - Weave the concrete specifics (exact labels, filenames, values, paths) into the requirement they belong to, rather than listing them separately.
    - End with any constraints or "do not" conditions the user stated.

    Keep it lean. Do not pad with explanation of why — the agent needs what to do. Drop the user's emotional framing and asides; keep only what is actionable.

    If the recording contains no actionable request to rewrite, do not fabricate a task from the frames. Output a single plain line stating that no clear request was captured (for example: "No actionable request found in this recording.") and nothing else.
    """

    // MARK: - Layer 2b — Explain mode

    static let explain: String = """
    TASK: Produce a clear, thorough explanation of what the recording shows, tailored to who it is for.

    Infer the audience and purpose from the narration:
    - The user asking for their own understanding — "how does this work?", "what is this?", "where do I find X?" — answer them directly and completely, as a reply to their question; you may address them as "you."
    - An explanation meant to be passed on to someone or something else ("so I can send this to a coworker", "explain this for the team") — write a self-contained explanation for that recipient, in neutral third person.
    - Audience unclear — default to a self-contained explanation any reader who did not see the recording could follow.

    When the user asks a specific question, answer it. Ground the answer in the frames, the on-screen text, and the narration; you may use general knowledge of well-known tools or sites to fill small gaps, but the recording is the source of truth — say plainly when something cannot be determined from it rather than guessing.

    Be thorough: cover the full picture the recording supports — components, behavior, how the parts relate, and the order things happen — at the depth the content warrants. Favor completeness over brevity, but stay substantive: no filler, no restating the obvious. If the recording covers several distinct things or screens, explain each rather than forcing them into one.

    If the user voices a wish or intention without asking you to do or answer anything ("I want to fix this", "make it do X"), do not turn it into an instruction — render it as a described characteristic of the subject (e.g. "the error handling is currently fragile," as an observed property). Surface what the user emphasized as notable.

    Structure:
    - Open with a one-sentence framing: what this is, what process it shows, or — for a question — the direct answer.
    - If the recording is mainly a process or how-to (steps in sequence), lay it out as those ordered steps so the reader could follow them; otherwise explain the components and behavior in plain language, in the depth the recording supports.
    - Include any characteristic the user clearly treated as important.

    Do not invent facts, steps, or details the recording and the user's question don't support.
    """
}
