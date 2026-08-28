/**
 * The user-facing model count, in one place.
 *
 * MIRROR — keep in sync with apps/desktop/Zerro/Services/ModelRegistry.swift,
 * the runtime source of truth. There is no build-time link between apps/web
 * and the desktop app, so this is an explicit mirror rather than a pretend
 * import; `lib/model-count-copy.test.ts` guards the copy that reads it, and
 * the Swift side derives its own count from its registry directly.
 *
 * The desktop registry holds 6 entries; `gpt-5.4-mini` is kill-switched
 * (enabled:false) but deliberately kept in the table so historic result
 * rows still resolve their model name. So: 6 registered, 5 selectable.
 */
export const SELECTABLE_MODEL_COUNT = 5;

/** How the vendors are named in prose, everywhere they're listed. */
export const MODEL_VENDORS = "Claude, GPT & Gemini";
