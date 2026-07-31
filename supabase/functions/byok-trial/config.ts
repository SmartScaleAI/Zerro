import { optionalEnvInt } from "../_shared/env.ts";

export const BYOK_TRIAL_GENERATIONS = optionalEnvInt(
  "BYOK_TRIAL_GENERATIONS",
  10,
);

export const BYOK_TRIAL_TOKEN_TTL_SECONDS = optionalEnvInt(
  "BYOK_TRIAL_TOKEN_TTL_SECONDS",
  24 * 60 * 60,
);

export const BYOK_TRIAL_RATE_LIMIT_PER_IP = optionalEnvInt(
  "BYOK_TRIAL_RATE_LIMIT_PER_IP",
  60,
);

export const BYOK_TRIAL_RATE_LIMIT_PER_DEVICE = optionalEnvInt(
  "BYOK_TRIAL_RATE_LIMIT_PER_DEVICE",
  30,
);

export const BYOK_TRIAL_RATE_LIMIT_WINDOW_SECONDS = optionalEnvInt(
  "BYOK_TRIAL_RATE_LIMIT_WINDOW_SECONDS",
  60 * 60,
);
