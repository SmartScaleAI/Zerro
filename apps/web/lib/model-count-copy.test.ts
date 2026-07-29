import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { SELECTABLE_MODEL_COUNT } from "./model-registry.ts";

// Run with: npm test  (Node's built-in runner strips the TS types natively)
//
// A grep-style guard on the user-facing model COUNT, mirroring the desktop's
// ZerroTests/ModelCountCopyGuardTests. `gpt-5.4-mini` is kill-switched but kept
// in the registry so historic rows resolve, which leaves 6 registered entries
// and 5 selectable — the copy said "6 models" for a while after that flip. These
// files are read off disk (not imported) so the static asset is covered by the
// same rule as the components.
//
// ⚠️ .github/workflows/ci.yml has no apps/web job yet, so this does NOT run on
// PRs. Until one exists, run `npm run test` in apps/web (or the rg one-liner in
// the PR description) by hand when touching pricing copy.

const WEB_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

/** Every shipped surface that states, or could state, a model count. */
const COPY_FILES = [
  "components/structured-data.tsx",
  "components/templates/axis/pricing.tsx",
  "components/templates/axis/faq-data.ts",
  "public/llms-full.txt",
];

/**
 * Files expected to actually state the count in prose. The three components
 * build it from SELECTABLE_MODEL_COUNT, so the literal only appears in the
 * static asset — which is exactly why that one needs a positive lock.
 */
const STATES_THE_COUNT_LITERALLY = ["public/llms-full.txt"];

const read = (relative: string) =>
  readFileSync(join(WEB_ROOT, relative), "utf8");

for (const relative of COPY_FILES) {
  test(`${relative} states no stale model count`, () => {
    const source = read(relative);
    const stale = /\b(6|six)\s+models\b/i.exec(source);
    assert.equal(
      stale,
      null,
      `${relative} still claims "${stale?.[0]}" — ${SELECTABLE_MODEL_COUNT} models are selectable (the 6th registry entry is kill-switched)`,
    );
  });
}

for (const relative of STATES_THE_COUNT_LITERALLY) {
  test(`${relative} states the current model count`, () => {
    const source = read(relative);
    assert.ok(
      source.includes(`${SELECTABLE_MODEL_COUNT} models`),
      `${relative} should say "${SELECTABLE_MODEL_COUNT} models" — a static asset can't import the constant, so it's pinned here`,
    );
  });
}

test("the components derive the count instead of hand-typing it", () => {
  for (const relative of COPY_FILES.filter(
    (f) => !STATES_THE_COUNT_LITERALLY.includes(f),
  )) {
    const source = read(relative);
    assert.ok(
      source.includes("SELECTABLE_MODEL_COUNT"),
      `${relative} should build its model-count copy from SELECTABLE_MODEL_COUNT`,
    );
    assert.ok(
      !/\b\d+\s+models\b/.test(source),
      `${relative} should not hand-type a model count alongside the derived one`,
    );
  }
});
