import {
  base64UrlDecode,
  base64UrlEncode,
  hmacSha256,
  timingSafeEqual,
  toHex,
} from "../_shared/crypto.ts";

interface OnboardingContactClaims {
  sub: string;
  kind: "onboarding_contact";
  iat: number;
  exp: number;
}

const header = { alg: "HS256", typ: "JWT" } as const;

export async function signOnboardingContactToken(
  contactId: string,
  secret: string,
  ttlSeconds: number,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<{ token: string; exp: number }> {
  const claims: OnboardingContactClaims = {
    sub: contactId,
    kind: "onboarding_contact",
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

export async function verifyOnboardingContactToken(
  token: string,
  secret: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<OnboardingContactClaims | null> {
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

  let claims: OnboardingContactClaims;
  try {
    claims = JSON.parse(
      new TextDecoder().decode(base64UrlDecode(payloadB64)),
    ) as OnboardingContactClaims;
  } catch {
    return null;
  }

  if (
    claims.kind !== "onboarding_contact" ||
    typeof claims.sub !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(claims.sub) ||
    typeof claims.exp !== "number" ||
    claims.exp <= nowSeconds
  ) {
    return null;
  }
  return claims;
}
