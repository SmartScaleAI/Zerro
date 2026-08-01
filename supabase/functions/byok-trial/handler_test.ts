import { assert, assertEquals } from "jsr:@std/assert@1";
import { handleBYOKTrial, type BYOKTrialDeps } from "./handler.ts";
import type {
  BYOKTrialResult,
  BYOKTrialStore,
} from "./store.ts";

const SECRET = "byok_trial_test_secret";
const NOW = 1_000_000;
const DEVICE = "a".repeat(64);

class InMemoryBYOKTrialStore implements BYOKTrialStore {
  trialKind: "none" | "managed" | "byok" = "none";
  used = 0;
  events = new Set<string>();
  rateOk = true;

  eligibility(_deviceIdHash: string): Promise<BYOKTrialResult> {
    switch (this.trialKind) {
      case "none":
        return Promise.resolve({
          status: "eligible",
          grantId: null,
          generationsRemaining: 10,
        });
      case "managed":
        return Promise.resolve({
          status: "managed_trial_used",
          grantId: null,
          generationsRemaining: 0,
        });
      case "byok":
        return Promise.resolve({
          status: this.used >= 10 ? "exhausted" : "active",
          grantId: "11111111-1111-4111-8111-111111111111",
          generationsRemaining: Math.max(0, 10 - this.used),
        });
    }
  }

  consume(
    _deviceIdHash: string,
    generationId: string,
    limit: number,
  ): Promise<BYOKTrialResult> {
    if (this.trialKind === "managed") {
      return Promise.resolve({
        status: "managed_trial_used",
        grantId: null,
        generationsRemaining: 0,
        counted: false,
      });
    }
    this.trialKind = "byok";
    const grantId = "11111111-1111-4111-8111-111111111111";
    if (this.events.has(generationId)) {
      return Promise.resolve({
        status: this.used >= limit ? "exhausted" : "active",
        grantId,
        generationsRemaining: Math.max(0, limit - this.used),
        counted: false,
      });
    }
    if (this.used >= limit) {
      return Promise.resolve({
        status: "exhausted",
        grantId,
        generationsRemaining: 0,
        counted: false,
      });
    }
    this.events.add(generationId);
    this.used += 1;
    return Promise.resolve({
      status: this.used >= limit ? "exhausted" : "active",
      grantId,
      generationsRemaining: Math.max(0, limit - this.used),
      counted: true,
    });
  }

  rateLimitOk(): Promise<boolean> {
    return Promise.resolve(this.rateOk);
  }
}

function deps(store: InMemoryBYOKTrialStore): BYOKTrialDeps {
  return { store, jwtSecret: SECRET, nowSeconds: NOW };
}

function request(
  body: unknown,
  token?: string,
): Request {
  const headers = new Headers({
    "Content-Type": "application/json",
    "x-forwarded-for": "203.0.113.7",
  });
  if (token) headers.set("Authorization", `Bearer ${token}`);
  return new Request("http://local/byok-trial", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

async function eligibleToken(
  store: InMemoryBYOKTrialStore,
): Promise<string> {
  const response = await handleBYOKTrial(
    request({ action: "eligibility", device_id_hash: DEVICE }),
    deps(store),
  );
  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(body.status, "eligible");
  assert(typeof body.token === "string");
  return body.token;
}

Deno.test("eligibility returns a device-bound anonymous token and no content fields", async () => {
  const store = new InMemoryBYOKTrialStore();
  const response = await handleBYOKTrial(
    request({ action: "eligibility", device_id_hash: DEVICE }),
    deps(store),
  );
  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(body.status, "eligible");
  assertEquals(body.generations_remaining, 10);
  assert(typeof body.token === "string");
  assertEquals(body.email, undefined);
  assertEquals(body.prompt, undefined);
  assertEquals(body.provider, undefined);
});

Deno.test("a Managed trial claim blocks the anonymous BYOK trial", async () => {
  const store = new InMemoryBYOKTrialStore();
  store.trialKind = "managed";
  const response = await handleBYOKTrial(
    request({ action: "eligibility", device_id_hash: DEVICE }),
    deps(store),
  );
  const body = await response.json();
  assertEquals(body.status, "managed_trial_used");
  assertEquals(body.generations_remaining, 0);
  assertEquals(body.token, undefined);
});

Deno.test("a successful generation is counted once across retries", async () => {
  const store = new InMemoryBYOKTrialStore();
  const token = await eligibleToken(store);
  const generationId = "22222222-2222-4222-8222-222222222222";

  const first = await handleBYOKTrial(
    request({ action: "complete", generation_id: generationId }, token),
    deps(store),
  );
  const firstBody = await first.json();
  assertEquals(firstBody.status, "active");
  assertEquals(firstBody.counted, true);
  assertEquals(firstBody.generations_remaining, 9);

  const retry = await handleBYOKTrial(
    request({ action: "complete", generation_id: generationId }, token),
    deps(store),
  );
  const retryBody = await retry.json();
  assertEquals(retryBody.counted, false);
  assertEquals(retryBody.generations_remaining, 9);
  assertEquals(store.used, 1);
});

Deno.test("the tenth result is delivered and the next completion stays exhausted", async () => {
  const store = new InMemoryBYOKTrialStore();
  const token = await eligibleToken(store);

  for (let index = 0; index < 10; index += 1) {
    const suffix = (index + 1).toString(16).padStart(12, "0");
    const response = await handleBYOKTrial(
      request({
        action: "complete",
        generation_id: `33333333-3333-4333-8333-${suffix}`,
      }, token),
      deps(store),
    );
    const body = await response.json();
    assertEquals(body.counted, true);
    assertEquals(body.generations_remaining, 9 - index);
    if (index === 9) assertEquals(body.status, "exhausted");
  }

  const extra = await handleBYOKTrial(
    request({
      action: "complete",
      generation_id: "44444444-4444-4444-8444-444444444444",
    }, token),
    deps(store),
  );
  const extraBody = await extra.json();
  assertEquals(extraBody.status, "exhausted");
  assertEquals(extraBody.counted, false);
  assertEquals(extraBody.generations_remaining, 0);
  assertEquals(store.used, 10);
});

Deno.test("completion requires a valid signed token and generation UUID", async () => {
  const store = new InMemoryBYOKTrialStore();
  const missingToken = await handleBYOKTrial(
    request({
      action: "complete",
      generation_id: "55555555-5555-4555-8555-555555555555",
    }),
    deps(store),
  );
  assertEquals(missingToken.status, 401);

  const token = await eligibleToken(store);
  const badId = await handleBYOKTrial(
    request({ action: "complete", generation_id: "not-a-uuid" }, token),
    deps(store),
  );
  assertEquals(badId.status, 400);
  assertEquals(store.used, 0);
});

Deno.test("rate limiting fails closed before trial state changes", async () => {
  const store = new InMemoryBYOKTrialStore();
  store.rateOk = false;
  const response = await handleBYOKTrial(
    request({ action: "eligibility", device_id_hash: DEVICE }),
    deps(store),
  );
  assertEquals(response.status, 429);
  assertEquals(store.trialKind, "none");
});
