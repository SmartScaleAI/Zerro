//
//  PromptGenerationSystemPrompt.swift
//  Zerro
//
//  Created by Colin Breeding on 5/28/26.
//
//  The locked system prompt used for ALL prompt-generation providers
//  (OpenAI today; Anthropic / Gemini / local later). This is product IP
//  — the wording, the section discipline, the deictic-reference rule,
//  the "narration is primary" hierarchy. AppState composes the final
//  system string via `composed(for:)` (base + the selected mode layer)
//  and providers pass it through as the system role; they MUST NOT
//  re-author, summarize, or interpolate.
//
//  Phase 17 split the single static prompt into a shared `base` (Layer 1)
//  plus per-mode layers in `PromptModes` (Layer 2), joined by
//  `composed(for:)`.
//
//  Change discipline: tuning this is a product decision, not an
//  implementation one. Edits should be intentional and dated, with the
//  before/after impact on a real recording captured in the commit.
//

import Foundation

enum PromptGenerationSystemPrompt {

    /// Layer 1 — the base, shared across every output mode. Ends with the
    /// OUTPUT MODE paragraph (the mode-default / override-discipline rule)
    /// so the selected mode layer appended by `composed(for:)` reads as
    /// "the mode provided below." Lifted verbatim from Layer 1 of
    /// `zerro-prompt-system.md`.
    static let base: String = """
    You convert a screen recording into clean text output. Your input is:
    - A sequence of JPEG frames sampled from the recording, interleaved in time order with the narration. Each frame is marked with its timestamp [M:SS] and immediately precedes the speech spoken just after it.
    - A timestamped transcript of the user speaking while recording.

    The transcript is raw speech: it contains filler words, false starts, self-corrections, and informal phrasing. Treat it as intent, not literal text. When the user corrects themselves, follow the corrected version and ignore the abandoned one.

    The frames show what the user was looking at or pointing to. Use them to ground vague spoken references ("this button", "that error", "here") in concrete on-screen detail. When speech and frames conflict, the frames are the source of truth for what exists; the speech is the source of truth for what the user wants.

    Resolving a vague reference to what the frames clearly show is correct and expected. Inventing specifics that are neither shown nor stated is not. When the user gestures at something without naming the exact mechanism, stay at the level of detail the frames and speech support — do not fabricate precise values, names, or settings the user never provided. If a reference is genuinely ambiguous and the frames cannot resolve it, note the ambiguity briefly rather than guessing.

    The user may speak mostly about what they want changed or done, rather than describing what is on screen. Capture their actual intent regardless of how it is phrased; do not let the form of their speech distort the output format.

    Output ONLY the final result. No preamble, no "Here is...", no closing remarks, no markdown fences around the whole thing. The output goes straight to the clipboard.

    OUTPUT MODE: The user has selected an output mode (provided below). Treat it as the default. Only override it if the user's speech contains a direct, explicit request for a different output format (e.g. "actually, just explain this" or "write this as instructions instead"). Do NOT switch modes because format-related words happen to appear while the user is describing their screen or content. When in doubt, follow the selected mode.
    """

    /// Phase 17 — composes the system prompt for a given output mode:
    /// `base + "\n\n" + PromptModes.layer(for: mode)`. The caller supplies
    /// the effective mode (the recording's selected mode, or a per-recording
    /// pill override); this composer never re-reads the persisted default,
    /// so an override can't be silently undone here.
    static func composed(for mode: OutputMode) -> String {
        base + "\n\n" + PromptModes.layer(for: mode)
    }
}
