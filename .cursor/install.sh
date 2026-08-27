#!/usr/bin/env bash
# Idempotent dependency refresh for the Zerro Cloud Agent environment.
#
# Scope (Linux Cloud Agent): the two targets that build/run on Linux —
#   * apps/web            Next.js 16 marketing site
#   * supabase/functions  Deno edge functions (their unit test suite)
# The macOS desktop app (apps/desktop) needs Xcode and only builds on macOS,
# and the Supabase local DB stack needs Docker + third-party API secrets, so
# neither is provisioned here.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Deno: runtime for the supabase/functions test suite ---------------------
# Installed to /usr/local (binary lands in /usr/local/bin/deno) so it is on PATH
# for every shell without touching any shell profile. Skip the download when a
# working deno is already present (keeps re-runs fast and idempotent).
if ! command -v deno >/dev/null 2>&1; then
  curl -fsSL https://deno.land/install.sh | sudo env DENO_INSTALL=/usr/local sh
fi
deno --version | head -1

# --- Web app dependencies ----------------------------------------------------
# npm ci installs exactly what apps/web/package-lock.json pins. The default
# Cloud Agent image's nvm-managed Node (>= 22.22) satisfies the project's
# engine requirement and runs the `node --test` TypeScript suites natively.
cd "$repo_root/apps/web"
npm ci

echo "Zerro dev environment ready: apps/web deps installed, deno $(deno --version | head -1 | awk '{print $2}') available."
