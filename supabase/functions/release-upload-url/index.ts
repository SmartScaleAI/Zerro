// =============================================================================
// release-upload-url — mints a one-time, path-scoped signed upload URL for the
// release DMG objects so CI never holds the service-role key (hardening L-01).
// =============================================================================
// Deployed with verify_jwt = false at the Supabase GATEWAY (see config.toml);
// gated HERE by a constant-time compare of the x-release-secret header against
// RELEASE_UPLOAD_SECRET — the same own-shared-secret pattern as
// refresh-agent-models. The service-role key lives ONLY in Edge secrets
// (auto-injected), never in GitHub Actions.
//
// The release uploads TWO objects (release-app.yml): the permanent versioned
// downloads/Zerro-<build>.dmg (the only one the appcast references) and the
// mutable "latest" downloads/Zerro.dmg — so the target name rides in the body
// and is validated against a strict allow-list BEFORE minting (validate.ts).
//
// Wire shape (owner swap recipe: README-backend.md → "Release DMG upload"):
//   POST /release-upload-url   x-release-secret: <RELEASE_UPLOAD_SECRET>
//   { "path": "Zerro-226.dmg" }            // or "Zerro.dmg"
//   → 200 { path, token, signedUrl }       // token never logged
//   → 400 { error: "invalid_body" }        // malformed JSON / path not a string
//   → 401 { error: "unauthorized" }        // bad/missing secret
//   → 403 { error: "invalid_path" }        // not an allow-listed Zerro DMG name
//   → 405 { error: "method_not_allowed" }
//   → 502 { error: "mint_failed" }         // storage refused to mint

import { requireEnv } from "../_shared/env.ts";
import { serviceClient } from "../_shared/db.ts";
import { handlePreflight, json } from "../_shared/http.ts";
import { isAllowedDmgPath, timingSafeEqual } from "./validate.ts";

Deno.serve(async (req: Request) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // Authenticate FIRST (before touching the body): constant-time compare so a
  // wrong secret can't be timed out byte-by-byte.
  const expected = requireEnv("RELEASE_UPLOAD_SECRET");
  const got = req.headers.get("x-release-secret") ?? "";
  if (!timingSafeEqual(got, expected)) return json({ error: "unauthorized" }, 401);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_body" }, 400);
  }
  const path = (body as { path?: unknown } | null)?.path;
  if (typeof path !== "string") return json({ error: "invalid_body" }, 400);
  // Allow-list the target BEFORE minting — this is what bounds a leaked secret
  // to "upload a Zerro DMG": no other object, no traversal, no nested path.
  if (!isAllowedDmgPath(path)) return json({ error: "invalid_path" }, 403);

  // upsert:true because BOTH targets legitimately overwrite: Zerro.dmg is the
  // mutable latest every release, and a same-tag re-run re-uploads the
  // versioned name (release-app.yml uses x-upsert for the same reason).
  const { data, error } = await serviceClient()
    .storage.from("downloads")
    .createSignedUploadUrl(path, { upsert: true });
  if (error || !data) return json({ error: "mint_failed" }, 502);

  // data.signedUrl is the relative path incl. ?token=… — the token IS the
  // auth, so the caller needs no Supabase key. Never logged.
  return json({ path: data.path, token: data.token, signedUrl: data.signedUrl });
});
