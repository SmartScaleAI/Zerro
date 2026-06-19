// =============================================================================
// prompt_test.ts — byte-identity enforcement for the locked prompt v2.
// =============================================================================
// The prompt's in-repo source of truth is the first fenced block of
// apps/desktop/Scripts/artifact-eval/prompt-v2.md (itself byte-identical to the
// canonical zerro-prompt-system.md v2). This test reads that mirror from the
// repo and compares it to composedSystemPrompt()'s output character-for-
// character, so a drifting copy fails the suite instead of relying on the
// KEEP IN SYNC comment.
//
// Needs --allow-read (repo file access) on top of the suite's usual flags:
//   deno test --allow-env --allow-net --allow-read generate/
// =============================================================================

import { assert, assertEquals } from "jsr:@std/assert@1";
import { composedSystemPrompt } from "./prompt.ts";

const MIRROR_URL = new URL(
  "../../../apps/desktop/Scripts/artifact-eval/prompt-v2.md",
  import.meta.url,
);

Deno.test("composedSystemPrompt() is byte-identical to the locked in-repo mirror", async () => {
  let md: string;
  try {
    md = await Deno.readTextFile(MIRROR_URL);
  } catch (e) {
    throw new Error(
      `could not read the prompt mirror at ${MIRROR_URL.pathname} — ` +
        `run the suite with --allow-read from supabase/functions/ inside the repo (${e})`,
    );
  }
  const fence = md.match(/\n```\n([\s\S]*?)\n```\n/);
  assert(fence, "prompt-v2.md has no fenced block — the mirror format changed?");

  const composed = composedSystemPrompt();
  const mirror = fence[1];
  if (composed !== mirror) {
    // assertEquals on 14k chars produces an unreadable diff; locate the first
    // divergence precisely instead.
    const n = Math.min(composed.length, mirror.length);
    let i = 0;
    while (i < n && composed[i] === mirror[i]) i++;
    throw new Error(
      `prompt.ts drifted from prompt-v2.md at char ${i}: ` +
        `composed …${JSON.stringify(composed.slice(Math.max(0, i - 40), i + 40))}… vs ` +
        `mirror …${JSON.stringify(mirror.slice(Math.max(0, i - 40), i + 40))}… ` +
        `(lengths ${composed.length} vs ${mirror.length})`,
    );
  }
  assertEquals(composed.length, 14_228, "locked v2 length — update alongside an intentional prompt change");
});

Deno.test("composedSystemPrompt() carries the v2 artifact contract, not the v1 modes", () => {
  const p = composedSystemPrompt();
  assert(p.includes("<<<ZERRO_ARTIFACT"), "v2 fence syntax present");
  assert(p.includes("<<<END_ZERRO_ARTIFACT>>>"), "v2 close fence present");
  assert(!p.includes("OUTPUT MODE:"), "v1 mode paragraph must be gone");
  assert(!p.includes("goes straight to the clipboard"), "v1 clipboard paragraph must be gone");
});

// Dev Mode (Phase 1, Milestone 5) — `mode:"dev"` selects the repo-scoped
// prompt. Structural assertions, not a byte-mirror (the dev prompt has no md
// source); it must stay in sync with the Swift `devText` by review.
Deno.test("composedSystemPrompt('dev') is the repo-scoped Dev Mode variant", () => {
  const dev = composedSystemPrompt("dev");
  const normal = composedSystemPrompt();
  assert(dev !== normal, "dev prompt must differ from the normal prompt");

  // The Goal / Changes / Scope / user said body shape (design §6).
  assert(dev.includes("Goal:"), "Goal: line");
  assert(dev.includes("Changes:"), "Changes: list");
  assert(dev.includes("Scope:"), "Scope: line");
  assert(dev.includes("user said:"), "verbatim user-said tiebreaker");

  // Eyes/hands framing — the agent has the repo but not the recording.
  assert(dev.includes("did NOT see the recording"), "agent blindness note");

  // Route context + runtime note + the CSS/quality constraints (§11 #1 failure).
  assert(dev.includes("localhost"), "route context");
  assert(dev.includes("hot reload"), "runtime hot-reload note");
  assert(dev.toLowerCase().includes("dark mode"), "dark-mode constraint");
  assert(dev.includes("smallest change"), "smallest-change constraint");
  assert(dev.includes("design token"), "existing-tokens constraint");
  assert(dev.includes("grepping"), "anchor-by-visible-text instruction");

  // Still emits the agent_prompt artifact fence the client parser expects.
  assert(dev.includes('type="agent_prompt"'), "agent_prompt artifact type");
  assert(dev.includes("<<<ZERRO_ARTIFACT"), "open fence");
  assert(dev.includes("<<<END_ZERRO_ARTIFACT>>>"), "close fence");
});

Deno.test("composedSystemPrompt() treats unknown/absent modes as normal", () => {
  // An old client (no mode) or a garbage value must get the locked v2 prompt —
  // never an error, never the dev prompt by accident.
  const normal = composedSystemPrompt();
  assertEquals(composedSystemPrompt("bogus"), normal);
  assertEquals(composedSystemPrompt("normal"), normal);
  assert(composedSystemPrompt("dev") !== normal);
});
