import { sha256Hex } from "../_shared/crypto.ts";
import { json } from "../_shared/http.ts";
import {
  BYOK_TRIAL_GENERATIONS,
  BYOK_TRIAL_RATE_LIMIT_PER_DEVICE,
  BYOK_TRIAL_RATE_LIMIT_PER_IP,
  BYOK_TRIAL_RATE_LIMIT_WINDOW_SECONDS,
  BYOK_TRIAL_TOKEN_TTL_SECONDS,
} from "./config.ts";
import type { BYOKTrialResult, BYOKTrialStore } from "./store.ts";
import { signBYOKTrialToken, verifyBYOKTrialToken } from "./token.ts";

export interface BYOKTrialDeps {
  store: BYOKTrialStore;
  jwtSecret: string;
  nowSeconds?: number;
}

function clientIp(req: Request): string {
  const forwarded = req.headers.get("x-forwarded-for");
  if (forwarded) return forwarded.split(",")[0].trim();
  return req.headers.get("x-real-ip") ?? "unknown";
}

function readDeviceHash(body: Record<string, unknown>): string | null {
  const raw = body.device_id_hash;
  if (typeof raw !== "string") return null;
  const normalized = raw.trim().toLowerCase();
  return /^[0-9a-f]{64}$/.test(normalized) ? normalized : null;
}

function readBearer(req: Request): string | null {
  const raw = req.headers.get("authorization") ?? "";
  return raw.toLowerCase().startsWith("bearer ")
    ? raw.slice(7).trim()
    : null;
}

async function rateLimit(
  req: Request,
  store: BYOKTrialStore,
  deviceIdHash: string,
): Promise<boolean> {
  const ipHash = await sha256Hex(clientIp(req));
  const ipOk = await store.rateLimitOk(
    `byok-trial:ip:${ipHash}`,
    BYOK_TRIAL_RATE_LIMIT_PER_IP,
    BYOK_TRIAL_RATE_LIMIT_WINDOW_SECONDS,
  );
  if (!ipOk) return false;
  return await store.rateLimitOk(
    `byok-trial:device:${deviceIdHash}`,
    BYOK_TRIAL_RATE_LIMIT_PER_DEVICE,
    BYOK_TRIAL_RATE_LIMIT_WINDOW_SECONDS,
  );
}

async function responseFor(
  result: BYOKTrialResult,
  deps: BYOKTrialDeps,
  deviceIdHash: string,
): Promise<Response> {
  if (
    result.status === "managed_trial_used" ||
    result.status === "invalid_device" ||
    result.status === "invalid_request"
  ) {
    return json({
      status: result.status,
      generations_remaining: result.generationsRemaining,
      generations_limit: BYOK_TRIAL_GENERATIONS,
      counted: result.counted ?? false,
    });
  }
  if (result.status === "server_error") {
    return json({ error: "server_error" }, 500);
  }

  const now = deps.nowSeconds ?? Math.floor(Date.now() / 1000);
  const signed = await signBYOKTrialToken(
    deviceIdHash,
    deps.jwtSecret,
    BYOK_TRIAL_TOKEN_TTL_SECONDS,
    now,
  );
  return json({
    status: result.status,
    token: signed.token,
    expires_at: new Date(signed.exp * 1000).toISOString(),
    trial_grant_id: result.grantId,
    generations_remaining: result.generationsRemaining,
    generations_limit: BYOK_TRIAL_GENERATIONS,
    counted: result.counted ?? false,
  });
}

export async function handleBYOKTrial(
  req: Request,
  deps: BYOKTrialDeps,
): Promise<Response> {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: Record<string, unknown>;
  try {
    body = await req.json() as Record<string, unknown>;
  } catch {
    return json({ error: "invalid_body" }, 400);
  }

  const action = String(body.action ?? "");
  if (!["eligibility", "resume", "complete"].includes(action)) {
    return json({ error: "invalid_action" }, 400);
  }

  if (action === "complete") {
    const bearer = readBearer(req);
    const now = deps.nowSeconds ?? Math.floor(Date.now() / 1000);
    const claims = bearer
      ? await verifyBYOKTrialToken(bearer, deps.jwtSecret, now)
      : null;
    if (!claims) return json({ error: "invalid_token" }, 401);

    const generationId = String(body.generation_id ?? "");
    if (
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
        .test(generationId)
    ) {
      return json({ error: "invalid_generation_id" }, 400);
    }
    if (!(await rateLimit(req, deps.store, claims.sub))) {
      return json({ error: "rate_limited" }, 429);
    }
    const result = await deps.store.consume(
      claims.sub,
      generationId,
      BYOK_TRIAL_GENERATIONS,
    );
    return await responseFor(result, deps, claims.sub);
  }

  const deviceIdHash = readDeviceHash(body);
  if (!deviceIdHash) return json({ error: "invalid_device" }, 400);
  if (!(await rateLimit(req, deps.store, deviceIdHash))) {
    return json({ error: "rate_limited" }, 429);
  }
  const result = await deps.store.eligibility(deviceIdHash);
  return await responseFor(result, deps, deviceIdHash);
}
