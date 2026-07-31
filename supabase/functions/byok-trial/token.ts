import {
  base64UrlDecode,
  base64UrlEncode,
  hmacSha256,
  timingSafeEqual,
  toHex,
} from "../_shared/crypto.ts";

interface BYOKTrialClaims {
  sub: string;
  kind: "byok_trial";
  iat: number;
  exp: number;
}

const header = { alg: "HS256", typ: "JWT" } as const;

export async function signBYOKTrialToken(
  deviceIdHash: string,
  secret: string,
  ttlSeconds: number,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<{ token: string; exp: number }> {
  const claims: BYOKTrialClaims = {
    sub: deviceIdHash,
    kind: "byok_trial",
    iat: nowSeconds,
    exp: nowSeconds + ttlSeconds,
  };
  const signingInput = `${base64UrlEncode(JSON.stringify(header))}.${
    base64UrlEncode(JSON.stringify(claims))
  }`;
  const signature = toHex(await hmacSha256(secret, signingInput));
  return {
    token: `${signingInput}.${base64UrlEncode(signature)}`,
    exp: claims.exp,
  };
}

export async function verifyBYOKTrialToken(
  token: string,
  secret: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<BYOKTrialClaims | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const [headerB64, payloadB64, signatureB64] = parts;
  const signingInput = `${headerB64}.${payloadB64}`;
  const expected = toHex(await hmacSha256(secret, signingInput));

  let provided: string;
  try {
    provided = new TextDecoder().decode(base64UrlDecode(signatureB64));
  } catch {
    return null;
  }
  if (!timingSafeEqual(expected, provided)) return null;

  let claims: BYOKTrialClaims;
  try {
    claims = JSON.parse(
      new TextDecoder().decode(base64UrlDecode(payloadB64)),
    ) as BYOKTrialClaims;
  } catch {
    return null;
  }

  if (
    claims.kind !== "byok_trial" ||
    typeof claims.sub !== "string" ||
    !/^[0-9a-f]{64}$/.test(claims.sub) ||
    typeof claims.exp !== "number" ||
    claims.exp <= nowSeconds
  ) {
    return null;
  }
  return claims;
}
