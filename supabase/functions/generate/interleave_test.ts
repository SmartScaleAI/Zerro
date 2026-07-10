// =============================================================================
// interleave_test.ts — the server half of the shared interleave golden fixture
// (J-07).
// =============================================================================
// The interleave wire-rendering is implemented three times (interleave.ts
// here, Interleaver + the BYOK encodeBody renderers in Swift, buildTimeline in
// apps/desktop/Scripts/eval-models.mjs) and kept aligned only by KEEP IN SYNC
// comments. This test and the Swift InterleaveGoldenFixtureTests both assert
// the SAME fixture (apps/desktop/Scripts/artifact-eval/interleave-golden.json,
// read repo-relative like prompt_test.ts), so a format drift on either side
// fails a suite instead of shipping. The eval harness copy is not import-safe
// (top-level main) and stays anchored by the comments.
//
// Needs --allow-read (repo file access) on top of the suite's usual flags.
// =============================================================================

import { assert, assertEquals } from "jsr:@std/assert@1";
import { buildInterleavedContent } from "./interleave.ts";

const FIXTURE_URL = new URL(
  "../../../apps/desktop/Scripts/artifact-eval/interleave-golden.json",
  import.meta.url,
);

Deno.test("buildInterleavedContent() matches the shared interleave golden fixture", async () => {
  let raw: string;
  try {
    raw = await Deno.readTextFile(FIXTURE_URL);
  } catch (e) {
    throw new Error(
      `could not read the interleave fixture at ${FIXTURE_URL.pathname} — ` +
        `run the suite with --allow-read from supabase/functions/ inside the repo (${e})`,
    );
  }
  const fixture = JSON.parse(raw);
  assert(Array.isArray(fixture.expectedBlocks), "fixture has no expectedBlocks — format changed?");

  const blocks = buildInterleavedContent(
    fixture.frames,
    fixture.segments,
    fixture.clicks,
  );

  // Reduce to the fixture's provider-neutral shape: text blocks byte-exact,
  // image blocks position-only (the base64 payload is not part of the golden).
  const rendered = blocks.map((b) =>
    b.type === "image" ? { image: true } : { text: b.text }
  );
  assertEquals(rendered, fixture.expectedBlocks);
});
