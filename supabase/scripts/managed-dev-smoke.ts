// =============================================================================
// managed-dev-smoke.ts — live billing + round-trip proof for the Dev Mode 2-call
// flow, run against a LOCAL `supabase functions serve` + the local DB.
// =============================================================================
// This is NOT a unit test (those live in handler_test.ts with stubbed providers).
// It drives the REAL function runtime + the REAL local Postgres to prove the
// billing invariants end-to-end on the wire:
//   • CALL 1 (dev_transcribe) → ZERO credit change, ZERO generation_log rows.
//   • CALL 2 (mode:"dev")     → EXACTLY the metered charge decremented once, the
//                               response carries an `anchors` array, and EXACTLY
//                               ONE generation_log row is written.
// It uses the no-speech/wire path (has_speech:false on call 1, an empty supplied
// transcript on call 2) — so it exercises the real round-trip + real chat call +
// real credit ledger WITHOUT needing a spoken recording. The model won't emit a
// `zerro_anchors` block for a synthetic blank frame, so `anchors` is expected to
// be an empty array here; a populated block is covered by handler_test.ts.
//
// Config comes from env (set by the runner, never echoed):
//   ZSMOKE_SECRET        — SESSION_JWT_SECRET the served function verifies with
//   ZSMOKE_SERVICE_ROLE  — local service-role key (PostgREST writes/reads)
//   ZSMOKE_MODEL         — chat model id (e.g. gemini-3.5-flash)
//   ZSMOKE_FUNCTIONS_URL / ZSMOKE_REST_URL — local endpoints
//
// Run:  deno run --allow-net --allow-env supabase/scripts/managed-dev-smoke.ts
// =============================================================================

import { signSessionToken } from "../functions/_shared/jwt.ts";

const SECRET = mustEnv("ZSMOKE_SECRET");
const SERVICE_ROLE = mustEnv("ZSMOKE_SERVICE_ROLE");
const MODEL = Deno.env.get("ZSMOKE_MODEL") || "gemini-3.5-flash";
const FUNCTIONS_URL = Deno.env.get("ZSMOKE_FUNCTIONS_URL") || "http://127.0.0.1:54321/functions/v1";
const REST_URL = Deno.env.get("ZSMOKE_REST_URL") || "http://127.0.0.1:54321/rest/v1";

// A real JPEG the chat provider can decode. Supplied by the runner via
// ZSMOKE_FRAME_B64 (a small re-encoded asset) — a synthetic 1x1 is rejected by
// some providers ("Unable to process input image").
const TINY_JPEG_B64 = mustEnv("ZSMOKE_FRAME_B64");

function mustEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) {
    console.error(`missing required env ${name}`);
    Deno.exit(2);
  }
  return v;
}

const restHeaders = {
  "apikey": SERVICE_ROLE,
  "Authorization": `Bearer ${SERVICE_ROLE}`,
  "Content-Type": "application/json",
};

async function restInsert(table: string, row: unknown) {
  const res = await fetch(`${REST_URL}/${table}`, {
    method: "POST",
    headers: { ...restHeaders, Prefer: "return=representation" },
    body: JSON.stringify(row),
  });
  if (!res.ok) throw new Error(`insert ${table} failed: ${res.status} ${await res.text()}`);
  return await res.json();
}

async function restSelect(path: string): Promise<any[]> {
  const res = await fetch(`${REST_URL}/${path}`, { headers: restHeaders });
  if (!res.ok) throw new Error(`select ${path} failed: ${res.status} ${await res.text()}`);
  return await res.json();
}

async function restDelete(path: string) {
  await fetch(`${REST_URL}/${path}`, { method: "DELETE", headers: restHeaders });
}

/** The latest period's credits_used + the count of generation_log rows. */
async function snapshot(subId: string): Promise<{ creditsUsed: number; logRows: number }> {
  const periods = await restSelect(
    `usage_periods?subscription_id=eq.${subId}&select=credits_used&order=period_start.desc&limit=1`,
  );
  const logs = await restSelect(`generation_log?subscription_id=eq.${subId}&select=id`);
  return { creditsUsed: Number(periods[0]?.credits_used ?? 0), logRows: logs.length };
}

let failures = 0;
function check(name: string, cond: boolean, extra = "") {
  console.log(`${cond ? "  ✅" : "  ❌"} ${name}${extra ? ` — ${extra}` : ""}`);
  if (!cond) failures++;
}

// ---- A throwaway uuid (no Math.random ban here — this is a script, not a workflow).
function uuid(): string {
  return crypto.randomUUID();
}

const subId = uuid();
const idemKey = `smoke-${uuid()}`;

console.log(`\n=== Managed Dev Mode 2-call live smoke ===`);
console.log(`subscription: ${subId}`);
console.log(`model: ${MODEL}\n`);

try {
  // --- Seed a fresh active subscription with a clean period (100 credits). ----
  await restInsert("subscriptions", {
    id: subId,
    ls_subscription_id: `smoke-${subId}`,
    tier: "managed", // single-managed-tier migration (20260616121000)
    status: "active",
    credits_limit: 100,
  });
  const now = new Date();
  await restInsert("usage_periods", {
    subscription_id: subId,
    period_start: now.toISOString(),
    period_end: new Date(now.getTime() + 30 * 864e5).toISOString(),
    credits_used: 0,
  });

  const token = (await signSessionToken({ sub: subId, tier: "managed", kind: "subscription" }, SECRET, 1800)).token;

  const before = await snapshot(subId);
  console.log(`BEFORE        credits_used=${before.creditsUsed}  generation_log_rows=${before.logRows}\n`);

  // --- CALL 1: dev_transcribe (free) -----------------------------------------
  const call1 = await fetch(`${FUNCTIONS_URL}/generate`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${token}`,
      "Idempotency-Key": `${idemKey}:dev-transcribe`,
    },
    body: JSON.stringify({
      mode: "dev_transcribe",
      audio: { mime: "audio/m4a", filename: "rec.m4a", data: btoa("fake-no-speech") },
      has_speech: false,
    }),
  });
  const call1Body = await call1.json().catch(() => ({}));
  const afterCall1 = await snapshot(subId);

  console.log(`CALL 1  POST /generate {mode:"dev_transcribe", has_speech:false}`);
  console.log(`        status=${call1.status}  transcript=${JSON.stringify(call1Body.transcript ?? null)}`);
  console.log(`AFTER 1       credits_used=${afterCall1.creditsUsed}  generation_log_rows=${afterCall1.logRows}\n`);
  check("call 1 → 200", call1.status === 200, `got ${call1.status}`);
  check("call 1 returns a transcript object", !!call1Body.transcript);
  check("call 1 charged ZERO credits", afterCall1.creditsUsed === before.creditsUsed,
    `Δ=${afterCall1.creditsUsed - before.creditsUsed}`);
  check("call 1 wrote ZERO generation_log rows", afterCall1.logRows === before.logRows,
    `Δ=${afterCall1.logRows - before.logRows}`);

  // --- CALL 2: mode:"dev" enriched generation (billable) ---------------------
  const call2 = await fetch(`${FUNCTIONS_URL}/generate`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${token}`,
      "Idempotency-Key": idemKey,
    },
    body: JSON.stringify({
      mode: "dev",
      model: MODEL,
      has_speech: true,
      // A minimal SYNTHETIC transcript (not a real recording) so the chat has
      // something concrete to produce — the billing + round-trip path is
      // identical regardless of content. Plus a trailing DEIXIS REFERENCE frame
      // so the dev prompt's `zerro_anchors` block can populate on the live wire.
      transcript: {
        segments: [{ start: 0, end: 2, text: "make this Get started button bigger" }],
        duration_seconds: 3,
      },
      frames: [
        { timestamp: 0, mime: "image/jpeg", data: TINY_JPEG_B64, ocr_text: "" },
        {
          timestamp: 99,
          mime: "image/jpeg",
          data: TINY_JPEG_B64,
          ocr_text:
            'DEIXIS REFERENCE 0: the developer pointed here while saying "this Get started button". The crosshair marks the element. Nearby on-screen text: Get started',
        },
      ],
      clicks: [],
    }),
  });
  const call2Body = await call2.json().catch(() => ({}));
  const afterCall2 = await snapshot(subId);

  console.log(`\nCALL 2  POST /generate {mode:"dev", transcript(no-audio), 1 frame}`);
  console.log(`        status=${call2.status}  credits_charged=${call2Body.credits_charged}  credits_remaining=${call2Body.credits_remaining}`);
  console.log(`        anchors=${JSON.stringify(call2Body.anchors ?? "MISSING")}`);
  console.log(`        prompt(first 80)=${JSON.stringify(String(call2Body.prompt ?? "").slice(0, 80))}`);
  console.log(`AFTER 2       credits_used=${afterCall2.creditsUsed}  generation_log_rows=${afterCall2.logRows}\n`);

  check("call 2 → 200", call2.status === 200, `got ${call2.status}: ${JSON.stringify(call2Body).slice(0, 200)}`);
  check("call 2 response CONTAINS an anchors[] array", Array.isArray(call2Body.anchors),
    `anchors=${JSON.stringify(call2Body.anchors)} (empty is expected for the synthetic blank frame)`);
  check("call 2 reports a metered charge ≥ 1", Number(call2Body.credits_charged) >= 1, `charged=${call2Body.credits_charged}`);
  const creditDelta = afterCall2.creditsUsed - afterCall1.creditsUsed;
  check("DB credits decremented by EXACTLY the charged amount", creditDelta === Number(call2Body.credits_charged),
    `db Δ=${creditDelta}, charged=${call2Body.credits_charged} (metered post-chat; amount varies by model/tokens)`);
  const logDelta = afterCall2.logRows - afterCall1.logRows;
  // "Exactly one charge" = ONE consume event + ONE generation_log row (not a per-
  // unit credit count — the metered amount is whatever the real cost dictates).
  check("EXACTLY ONE charge event for the dev generation (single consume + single log row)",
    logDelta === 1 && creditDelta === Number(call2Body.credits_charged) && Number(call2Body.credits_charged) >= 1,
    `logΔ=${logDelta}, creditΔ=${creditDelta}`);

  // --- Idempotent replay: same Idempotency-Key → cached result, NO 2nd charge -
  const replay = await fetch(`${FUNCTIONS_URL}/generate`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${token}`,
      "Idempotency-Key": idemKey, // SAME key as call 2
    },
    body: JSON.stringify({
      mode: "dev",
      model: MODEL,
      has_speech: true,
      transcript: { segments: [{ start: 0, end: 2, text: "make this Get started button bigger" }], duration_seconds: 3 },
      frames: [{ timestamp: 0, mime: "image/jpeg", data: TINY_JPEG_B64, ocr_text: "" }],
      clicks: [],
    }),
  });
  const replayBody = await replay.json().catch(() => ({}));
  const afterReplay = await snapshot(subId);
  console.log(`\nREPLAY  POST /generate (SAME Idempotency-Key)`);
  console.log(`        status=${replay.status}  credits_charged=${replayBody.credits_charged}`);
  console.log(`AFTER R       credits_used=${afterReplay.creditsUsed}  generation_log_rows=${afterReplay.logRows}\n`);
  check("replay → 200", replay.status === 200, `got ${replay.status}`);
  check("replay charges NOTHING extra (DB credits unchanged)", afterReplay.creditsUsed === afterCall2.creditsUsed,
    `db Δ since call 2 = ${afterReplay.creditsUsed - afterCall2.creditsUsed}`);
  check("replay writes NO new generation_log row", afterReplay.logRows === afterCall2.logRows,
    `Δ since call 2 = ${afterReplay.logRows - afterCall2.logRows}`);
  check("replay reports the ORIGINAL charge (not a new one)", Number(replayBody.credits_charged) === Number(call2Body.credits_charged),
    `replay=${replayBody.credits_charged}, original=${call2Body.credits_charged}`);
  check("replay still returns anchors[]", Array.isArray(replayBody.anchors));

  // --- Report the generation_log row -----------------------------------------
  const rows = await restSelect(
    `generation_log?subscription_id=eq.${subId}&select=*&order=created_at.desc&limit=1`,
  );
  console.log(`generation_log row:\n${JSON.stringify(rows[0] ?? null, null, 2)}\n`);

  // --- Cleanup ----------------------------------------------------------------
  await restDelete(`generation_log?subscription_id=eq.${subId}`);
  await restDelete(`usage_periods?subscription_id=eq.${subId}`);
  await restDelete(`idempotency_cache?key=like.*${subId}*`); // best-effort
  await restDelete(`subscriptions?id=eq.${subId}`);

  console.log(failures === 0
    ? `\n=== ✅ ALL CHECKS PASSED (${0} failures) ===`
    : `\n=== ❌ ${failures} CHECK(S) FAILED ===`);
  Deno.exit(failures === 0 ? 0 : 1);
} catch (e) {
  console.error(`\nSMOKE ERROR: ${e instanceof Error ? e.message : String(e)}`);
  // Best-effort cleanup on error.
  await restDelete(`generation_log?subscription_id=eq.${subId}`).catch(() => {});
  await restDelete(`usage_periods?subscription_id=eq.${subId}`).catch(() => {});
  await restDelete(`subscriptions?id=eq.${subId}`).catch(() => {});
  Deno.exit(3);
}
