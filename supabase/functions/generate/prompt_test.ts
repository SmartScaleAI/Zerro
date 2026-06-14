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
