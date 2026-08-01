#!/usr/bin/env bash
# Shared implementation. Use reset-local.sh, reset-staging.sh, or
# reset-production.sh instead of invoking this file directly.
set -euo pipefail

ENVIRONMENT="${1:-}"
[[ -n "$ENVIRONMENT" ]] || { echo "Missing environment." >&2; exit 2; }
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SQL_TEMPLATE="$SCRIPT_DIR/reset-user-data.sql"
LOCAL_RESET="$REPO_ROOT/apps/desktop/reset-for-testing.sh"
LOCAL_ENV_FILE="$REPO_ROOT/supabase/.env.local"

# Read only the two reset connection strings. Do not `source` .env.local: it is
# a data file, and evaluating every secret as shell code is unnecessary.
read_local_env_value() {
  local key="$1"
  local value=""
  [[ -f "$LOCAL_ENV_FILE" ]] || { printf '%s' ""; return; }
  value="$(sed -n "s/^${key}=//p" "$LOCAL_ENV_FILE" | tail -1)"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s' "$value"
}

if [[ -z "${ZERRO_STAGING_DB_URL:-}" ]]; then
  ZERRO_STAGING_DB_URL="$(read_local_env_value ZERRO_STAGING_DB_URL)"
fi
if [[ -z "${ZERRO_PRODUCTION_DB_URL:-}" ]]; then
  ZERRO_PRODUCTION_DB_URL="$(read_local_env_value ZERRO_PRODUCTION_DB_URL)"
fi

EMAIL=""
CLIENT_IP=""
INCLUDE_BILLING=false
DELETE_APP=false
ASSUME_YES=false
PREVIEW_ONLY=false

usage() {
  cat <<EOF
Usage: $(basename "$0") ENVIRONMENT --email EMAIL [options]

Options:
  --email EMAIL       Email used during onboarding (required)
  --client-ip IP      Also clear this IP's onboarding/session rate-limit rows
  --include-billing   Delete matching Supabase subscription mirror + ledgers
  --delete-app        Also delete the selected app from /Applications
  --preview-only      Show matching rows and exit without deleting anything
  --yes               Skip confirmation (not allowed for production)
  --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)
      [[ $# -ge 2 ]] || { echo "Missing value for --email" >&2; exit 2; }
      EMAIL="$2"
      shift 2
      ;;
    --client-ip)
      [[ $# -ge 2 ]] || { echo "Missing value for --client-ip" >&2; exit 2; }
      CLIENT_IP="$2"
      shift 2
      ;;
    --include-billing)
      INCLUDE_BILLING=true
      shift
      ;;
    --delete-app)
      DELETE_APP=true
      shift
      ;;
    --preview-only)
      PREVIEW_ONLY=true
      shift
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$ENVIRONMENT" in
  local)
    PROJECT_REF="local"
    DB_URL=""
    CONFIRM_ENV="LOCAL"
    DB_VAR_NAME=""
    ;;
  staging)
    PROJECT_REF="waripvlpcpwdmacpjiqc"
    DB_URL="${ZERRO_STAGING_DB_URL:-}"
    CONFIRM_ENV="STAGING"
    DB_VAR_NAME="ZERRO_STAGING_DB_URL"
    ;;
  production)
    PROJECT_REF="wjxqmurgwyxwkezncxke"
    DB_URL="${ZERRO_PRODUCTION_DB_URL:-}"
    CONFIRM_ENV="PRODUCTION"
    DB_VAR_NAME="ZERRO_PRODUCTION_DB_URL"
    ;;
  *)
    echo "Environment must be local, staging, or production." >&2
    exit 2
    ;;
esac

[[ -n "$EMAIL" ]] || { echo "--email is required." >&2; usage >&2; exit 2; }
[[ "$EMAIL" != *$'\n'* && "$EMAIL" == *@* && "$EMAIL" != @* && "$EMAIL" != *@ ]] \
  || { echo "--email does not look valid." >&2; exit 2; }

if [[ -n "$CLIENT_IP" && ! "$CLIENT_IP" =~ ^[0-9A-Fa-f:.]+$ ]]; then
  echo "--client-ip must be an IPv4 or IPv6 address." >&2
  exit 2
fi

if [[ "$ENVIRONMENT" != "local" ]]; then
  [[ -n "$DB_URL" ]] || {
    echo "$DB_VAR_NAME is required in supabase/.env.local (or the shell environment). Copy the encoded Postgres connection string from that Supabase project's Connect dialog." >&2
    exit 2
  }
  if [[ "$DB_URL" != *"postgres.$PROJECT_REF:"* \
     && "$DB_URL" != *"@db.$PROJECT_REF.supabase.co"* ]]; then
    echo "$DB_VAR_NAME does not identify the expected project ref $PROJECT_REF; refusing to run." >&2
    exit 2
  fi
fi

if [[ "$ENVIRONMENT" == "production" && "$ASSUME_YES" == true ]]; then
  echo "--yes is intentionally disabled for production." >&2
  exit 2
fi

for command_name in supabase xxd ioreg shasum sed; do
  command -v "$command_name" >/dev/null 2>&1 \
    || { echo "Required command not found: $command_name" >&2; exit 1; }
done

DEVICE_SALT="$(sed -n 's/.*private static let salt = "\([0-9a-f]*\)".*/\1/p' "$REPO_ROOT/apps/desktop/Zerro/Services/Managed/DeviceIdentity.swift")"
[[ "$DEVICE_SALT" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "Could not read DeviceIdentity salt from the app source." >&2; exit 1; }

PLATFORM_UUID="$(ioreg -rd1 -c IOPlatformExpertDevice | sed -n 's/.*"IOPlatformUUID" = "\([^"]*\)".*/\1/p' | head -1)"
[[ -n "$PLATFORM_UUID" ]] \
  || { echo "Could not read this Mac's IOPlatformUUID; refusing an incomplete first-user reset." >&2; exit 1; }
DEVICE_HASH="$(printf '%s' "${PLATFORM_UUID}${DEVICE_SALT}" | shasum -a 256 | sed 's/[[:space:]].*//')"

EMAIL_HEX="$(printf '%s' "$EMAIL" | xxd -p -c 100000)"
CLIENT_IP_HEX="$(printf '%s' "$CLIENT_IP" | xxd -p -c 100000)"
INCLUDE_SQL=false
[[ "$INCLUDE_BILLING" == true ]] && INCLUDE_SQL=true

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zerro-reset.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

render_sql() {
  local execute_value="$1"
  local output_file="$2"
  sed \
    -e "s/__EMAIL_HEX__/$EMAIL_HEX/g" \
    -e "s/__CLIENT_IP_HEX__/$CLIENT_IP_HEX/g" \
    -e "s/__DEVICE_HASH__/$DEVICE_HASH/g" \
    -e "s/__ENVIRONMENT__/$ENVIRONMENT/g" \
    -e "s/__INCLUDE_BILLING__/$INCLUDE_SQL/g" \
    -e "s/__EXECUTE__/$execute_value/g" \
    "$SQL_TEMPLATE" > "$output_file"
}

run_query() {
  local sql_file="$1"
  if [[ "$ENVIRONMENT" == "local" ]]; then
    SUPABASE_TELEMETRY_DISABLED=1 supabase db query --local --file "$sql_file" --output table
  else
    SUPABASE_TELEMETRY_DISABLED=1 supabase db query --db-url "$DB_URL" --file "$sql_file" --output table
  fi
}

PREVIEW_SQL="$TEMP_DIR/preview.sql"
EXECUTE_SQL="$TEMP_DIR/execute.sql"
render_sql false "$PREVIEW_SQL"

echo "==> Previewing the account-scoped reset in $ENVIRONMENT ($PROJECT_REF)"
run_query "$PREVIEW_SQL"

if [[ "$PREVIEW_ONLY" == true ]]; then
  echo "Preview complete. Nothing was deleted."
  exit 0
fi

if [[ "$INCLUDE_BILLING" == true ]]; then
  echo "WARNING: --include-billing removes the matching Supabase billing mirror and ledgers."
  echo "It does not cancel or delete anything in LemonSqueezy."
fi

if [[ -z "$CLIENT_IP" ]]; then
  echo "Note: no --client-ip was supplied, so IP-based rate-limit rows will remain."
fi

if [[ "$ENVIRONMENT" == "local" || "$ENVIRONMENT" == "production" ]]; then
  echo "Note: Local and Production currently share com.cbreeding.Zerro; their on-Mac state cannot be reset independently."
fi

if [[ "$ASSUME_YES" != true ]]; then
  EXPECTED="RESET $CONFIRM_ENV $EMAIL"
  printf "Type '%s' to continue: " "$EXPECTED"
  IFS= read -r CONFIRMATION
  [[ "$CONFIRMATION" == "$EXPECTED" ]] || { echo "Reset cancelled."; exit 1; }
fi

render_sql true "$EXECUTE_SQL"
echo "==> Deleting scoped Supabase rows"
run_query "$EXECUTE_SQL"

LOCAL_ARGS=(--environment "$ENVIRONMENT")
[[ "$DELETE_APP" == true ]] && LOCAL_ARGS+=(--delete-app)

echo "==> Deleting local app state, permissions, Keychain items, and the shared Whisper model"
bash "$LOCAL_RESET" "${LOCAL_ARGS[@]}"

echo "Reset complete for $ENVIRONMENT. The next launch should enter first-time onboarding."
