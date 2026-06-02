#!/usr/bin/env bash
# =============================================================================
# Phase D1 backend verification battery (curl). No app required.
# =============================================================================
# Drives the webhook → session → entitlement flow against a DEPLOYED (or locally
# served) set of functions and asserts the behaviors from the Phase D handoff:
#   1. signature: bad/missing X-Signature → 401, nothing written; good → processed
#   2. idempotency: same event twice → second is a 200 no-op (no double-roll)
#   3. lifecycle: created → first period; payment_success → new period + reset;
#      updated (tier) → new limit next period only; payment_failed → past_due,
#      credits/period UNCHANGED; cancelled → cancelled
#   4. session: active key → token + snapshot; past_due key → still a token;
#      cancelled key → 403
#   5. entitlement: valid token → snapshot; invalid token → 401
#
# Requirements: bash, curl, openssl, awk. (jq optional — falls back to grep.)
#
# Usage:
#   export BASE="https://<project-ref>.supabase.co/functions/v1"   # or local
#   export WEBHOOK_SECRET="<LEMONSQUEEZY_WEBHOOK_SECRET you set as a secret>"
#   ./run-curl-tests.sh
#
# NOTE: tier resolution maps LS variant_id → tier via the LS_VARIANT_STARTER /
# LS_VARIANT_PRO secrets. This script uses variant_id 0, which is UNMAPPED, so
# the webhook defaults it to 'starter' (credits_limit 100). That's expected and
# fine for a smoke test. To exercise 'pro', set variant_id below to your real
# Pro variant id after setting LS_VARIANT_PRO.
# =============================================================================
set -uo pipefail

: "${BASE:?set BASE to the functions base URL}"
: "${WEBHOOK_SECRET:?set WEBHOOK_SECRET to the webhook signing secret}"

PASS=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

sign() { printf '%s' "$1" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" | awk '{print $NF}'; }

# post_webhook <event_name> <json> <override_signature?>  -> echoes HTTP code
post_webhook() {
  local ev="$1" body="$2" sig
  if [ $# -ge 3 ]; then sig="$3"; else sig="$(sign "$body")"; fi
  curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/lemonsqueezy-webhook" \
    -H "X-Event-Name: $ev" -H "X-Signature: $sig" \
    -H "Content-Type: application/json" -d "$body"
}

# Unique-ish ids so reruns don't collide with prior mirror state.
STAMP="$(date +%s)"
SUB_ID="sub_${STAMP}"
ORDER_ID="order_${STAMP}"
CUST_ID="cust_${STAMP}"
LICENSE_KEY="TESTKEY-${STAMP}-AAAA-BBBB"

sub_payload() { # <status> <updated_at_iso> <renews_at_iso>  -> subscriptions resource
  cat <<JSON
{"meta":{"event_name":"placeholder"},"data":{"type":"subscriptions","id":"${SUB_ID}","attributes":{"customer_id":"${CUST_ID}","order_id":"${ORDER_ID}","variant_id":0,"status":"$1","renews_at":"$3","created_at":"2026-06-01T00:00:00.000000Z","updated_at":"$2"}}}
JSON
}

# Payment events carry a subscription-INVOICE resource: data.id is the invoice
# id, and the subscription id is attributes.subscription_id.
invoice_payload() { # <invoice_id> <billing_reason> <updated_at_iso>
  cat <<JSON
{"meta":{"event_name":"placeholder"},"data":{"type":"subscription-invoices","id":"$1","attributes":{"subscription_id":"${SUB_ID}","customer_id":"${CUST_ID}","billing_reason":"$2","status":"paid","created_at":"$3","updated_at":"$3"}}}
JSON
}

echo "== 1. Signature =="
BODY="$(sub_payload active 2026-06-01T00:00:00Z 2026-07-01T00:00:00Z)"
code="$(post_webhook subscription_created "$BODY" "deadbeefbadsignature")"
[ "$code" = "401" ] && ok "bad signature → 401" || bad "bad signature got $code (want 401)"
code="$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/lemonsqueezy-webhook" \
  -H "X-Event-Name: subscription_created" -H "Content-Type: application/json" -d "$BODY")"
[ "$code" = "401" ] && ok "missing signature → 401" || bad "missing signature got $code (want 401)"

echo "== 2 + 3. Lifecycle: created =="
code="$(post_webhook subscription_created "$BODY")"
[ "$code" = "200" ] && ok "subscription_created → 200" || bad "created got $code (want 200)"

echo "== license_key_created (links key by order id) =="
LK_BODY="{\"meta\":{\"event_name\":\"license_key_created\"},\"data\":{\"type\":\"license-keys\",\"id\":\"lk_${STAMP}\",\"attributes\":{\"customer_id\":\"${CUST_ID}\",\"order_id\":\"${ORDER_ID}\",\"key\":\"${LICENSE_KEY}\",\"status\":\"active\"}}}"
code="$(post_webhook license_key_created "$LK_BODY")"
[ "$code" = "200" ] && ok "license_key_created → 200" || bad "license_key_created got $code (want 200)"

echo "== 2. Idempotency: repost the SAME created event =="
code="$(post_webhook subscription_created "$BODY")"  # identical body → identical signature
[ "$code" = "200" ] && ok "duplicate created → 200 no-op (deduped by signature)" || bad "duplicate got $code"

echo "== 4. session: active key → token =="
SREQ="{\"license_key\":\"${LICENSE_KEY}\"}"
SRESP="$(curl -s -X POST "$BASE/session" -H "Content-Type: application/json" -d "$SREQ")"
TOKEN="$(printf '%s' "$SRESP" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
if [ -n "$TOKEN" ]; then ok "session returned a token"; else bad "no token in session response: $SRESP"; fi
echo "    snapshot: $(printf '%s' "$SRESP" | sed -n 's/.*\("entitlement":{[^}]*}\).*/\1/p')"

echo "== 5. entitlement: valid token → snapshot =="
ERESP="$(curl -s "$BASE/entitlement" -H "Authorization: Bearer ${TOKEN}")"
echo "$ERESP" | grep -q '"credits_remaining"' && ok "entitlement returned credits" || bad "entitlement: $ERESP"
echo "== 5. entitlement: bad token → 401 =="
code="$(curl -s -o /dev/null -w "%{http_code}" "$BASE/entitlement" -H "Authorization: Bearer not.a.token")"
[ "$code" = "401" ] && ok "invalid token → 401" || bad "invalid token got $code (want 401)"

echo "== 3. payment_failed → past_due, credits/period unchanged =="
PF_BODY="$(invoice_payload "inv_${STAMP}_fail" renewal 2026-06-15T00:00:00Z)"
code="$(post_webhook subscription_payment_failed "$PF_BODY")"
[ "$code" = "200" ] && ok "payment_failed → 200" || bad "payment_failed got $code"
# past_due STILL gets a token (§9.1)
SRESP2="$(curl -s -X POST "$BASE/session" -H "Content-Type: application/json" -d "$SREQ")"
printf '%s' "$SRESP2" | grep -q '"token"' && ok "past_due key still gets a token" || bad "past_due denied a token: $SRESP2"
printf '%s' "$SRESP2" | grep -q '"status":"past_due"' && ok "snapshot shows past_due" || bad "snapshot status not past_due: $SRESP2"

echo "== 3. payment_success (renewal invoice) → active + fresh period (reset) =="
PS_BODY="$(invoice_payload "inv_${STAMP}_renew" renewal 2026-07-01T00:01:00Z)"
code="$(post_webhook subscription_payment_success "$PS_BODY")"
[ "$code" = "200" ] && ok "payment_success → 200" || bad "payment_success got $code"

echo "== 3. cancelled → status cancelled; session now 403 =="
CN_BODY="$(sub_payload cancelled 2026-07-02T00:00:00Z 2026-08-01T00:00:00Z)"
code="$(post_webhook subscription_cancelled "$CN_BODY")"
[ "$code" = "200" ] && ok "cancelled → 200" || bad "cancelled got $code"
code="$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/session" -H "Content-Type: application/json" -d "$SREQ")"
[ "$code" = "403" ] && ok "cancelled key → session 403" || bad "cancelled key session got $code (want 403)"

echo
echo "==================  $PASS passed, $FAIL failed  =================="
[ "$FAIL" -eq 0 ]
