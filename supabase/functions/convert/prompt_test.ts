// =============================================================================
// prompt_test.ts — byte-identity enforcement for the locked conversion prompt
// v1 (Phase 6). The in-repo source of truth is the first fenced block of
// apps/desktop/Scripts/artifact-eval/convert-prompt-v1.md; same pattern as
// generate/prompt_test.ts.
//
// Needs --allow-read (repo file access) on top of the suite's usual flags:
//   deno test --allow-env --allow-net --allow-read convert/
// =============================================================================

import { assert, assertEquals } from "jsr:@std/assert@1";
import { conversionSystemPrompt } from "./prompt.ts";

const MIRROR_URL = new URL(
  "../../../apps/desktop/Scripts/artifact-eval/convert-prompt-v1.md",
  import.meta.url,
);

Deno.test("conversionSystemPrompt() is byte-identical to the locked in-repo mirror", async () => {
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
  assert(fence, "convert-prompt-v1.md has no fenced block — the mirror format changed?");

  const composed = conversionSystemPrompt();
  const mirror = fence[1];
  if (composed !== mirror) {
    const n = Math.min(composed.length, mirror.length);
    let i = 0;
    while (i < n && composed[i] === mirror[i]) i++;
    throw new Error(
      `convert/prompt.ts drifted from convert-prompt-v1.md at char ${i}: ` +
        `composed …${JSON.stringify(composed.slice(Math.max(0, i - 40), i + 40))}… vs ` +
        `mirror …${JSON.stringify(mirror.slice(Math.max(0, i - 40), i + 40))}… ` +
        `(lengths ${composed.length} vs ${mirror.length})`,
    );
  }
  assertEquals(composed.length, 3_413, "locked v1 length — update alongside an intentional prompt change");
});

Deno.test("conversionSystemPrompt() carries the §2 fence contract and the agent_prompt voice rules", () => {
  const p = conversionSystemPrompt();
  assert(p.includes('<<<ZERRO_ARTIFACT type="agent_prompt"'), "agent_prompt fence example present");
  assert(p.includes("<<<END_ZERRO_ARTIFACT>>>"), "close fence present");
  assert(p.includes('The phrase "the user" must not appear'), "voice ban carried over from v2");
  assert(p.includes("output ONLY the artifact block"), "block-only output contract present");
});
