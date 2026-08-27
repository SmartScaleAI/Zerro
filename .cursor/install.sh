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

# Make the image's nvm-managed Node/npm available even when this script runs in
# a non-login shell that has not sourced ~/.bashrc (where nvm is normally set
# up). Without this, `npm` may be missing depending on how `install` is invoked.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if ! command -v npm >/dev/null 2>&1 && [ -s "$NVM_DIR/nvm.sh" ]; then
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
fi

# --- Make `node` resolve to the image's nvm Node (>= 22.22) ------------------
# The Cloud Agent runtime prepends /exec-daemon (which bundles Node 22.14) to
# PATH ahead of the image's nvm-managed Node, so a bare `node` in agent and
# login shells lacks the native TypeScript type-stripping (Node >= 22.18) that
# apps/web's `node --test "lib/**/*.test.ts"` suite relies on. Append a small,
# idempotent block to ~/.bashrc that prepends the nvm default Node's bin dir so
# it wins over the bundled node. Everything else already works on 22.14, but
# `npm test` needs this. Guarded by a marker so re-runs don't duplicate it.
bashrc="$HOME/.bashrc"
marker="# zerro-cloud-agent: prefer nvm node on PATH"
if [ -f "$bashrc" ] && ! grep -qF "$marker" "$bashrc"; then
  cat >> "$bashrc" <<'EOF'

# zerro-cloud-agent: prefer nvm node on PATH
# The runtime prepends /exec-daemon (Node 22.14) ahead of the nvm Node; move the
# nvm default Node (>= 22.22, has native TS type-stripping) to the front so a
# bare `node` can run apps/web's `node --test *.ts` suite. See .cursor/install.sh.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
__zerro_node_bin="$(dirname "$(nvm which default 2>/dev/null)" 2>/dev/null)"
if [ -n "$__zerro_node_bin" ] && [ -x "$__zerro_node_bin/node" ]; then
  case ":$PATH:" in
    *":$__zerro_node_bin:"*) PATH="$__zerro_node_bin:${PATH//":$__zerro_node_bin:"/":"}" ;;
    *) PATH="$__zerro_node_bin:$PATH" ;;
  esac
  export PATH
fi
unset __zerro_node_bin
EOF
fi

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
