import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";

export interface BYOKTrialResult {
  status:
    | "eligible"
    | "active"
    | "exhausted"
    | "managed_trial_used"
    | "invalid_device"
    | "invalid_request"
    | "server_error";
  grantId: string | null;
  generationsRemaining: number;
  counted?: boolean;
}

export interface BYOKTrialStore {
  eligibility(deviceIdHash: string): Promise<BYOKTrialResult>;
  consume(
    deviceIdHash: string,
    generationId: string,
    limit: number,
  ): Promise<BYOKTrialResult>;
  rateLimitOk(
    key: string,
    max: number,
    windowSeconds: number,
  ): Promise<boolean>;
}

function mapRow(row: Record<string, unknown>): BYOKTrialResult {
  return {
    status: String(row.status) as BYOKTrialResult["status"],
    grantId: row.grant_id ? String(row.grant_id) : null,
    generationsRemaining: Math.max(
      0,
      Number(row.generations_remaining ?? 0),
    ),
    counted: row.counted === undefined ? undefined : row.counted === true,
  };
}

export class SupabaseBYOKTrialStore implements BYOKTrialStore {
  constructor(private readonly db: SupabaseClient) {}

  async eligibility(deviceIdHash: string): Promise<BYOKTrialResult> {
    const { data, error } = await this.db.rpc(
      "check_byok_trial_eligibility",
      { p_device_id_hash: deviceIdHash },
    );
    if (error) {
      console.error(JSON.stringify({
        fn: "byok-trial",
        op: "eligibility",
        error: error.message,
      }));
      throw error;
    }
    const row = Array.isArray(data) ? data[0] : data;
    if (!row) throw new Error("check_byok_trial_eligibility returned no row");
    return mapRow(row as Record<string, unknown>);
  }

  async consume(
    deviceIdHash: string,
    generationId: string,
    limit: number,
  ): Promise<BYOKTrialResult> {
    const { data, error } = await this.db.rpc(
      "consume_byok_trial_generation",
      {
        p_device_id_hash: deviceIdHash,
        p_generation_id: generationId,
        p_limit: limit,
      },
    );
    if (error) {
      console.error(JSON.stringify({
        fn: "byok-trial",
        op: "consume",
        error: error.message,
      }));
      throw error;
    }
    const row = Array.isArray(data) ? data[0] : data;
    if (!row) throw new Error("consume_byok_trial_generation returned no row");
    return mapRow(row as Record<string, unknown>);
  }

  async rateLimitOk(
    key: string,
    max: number,
    windowSeconds: number,
  ): Promise<boolean> {
    const { data, error } = await this.db.rpc("check_rate_limit", {
      p_key: key,
      p_max: max,
      p_window_seconds: windowSeconds,
    });
    if (error) {
      console.error(JSON.stringify({
        fn: "byok-trial",
        event: "rate_limiter_error",
        error: error.message,
      }));
      return false;
    }
    return data === true;
  }
}
