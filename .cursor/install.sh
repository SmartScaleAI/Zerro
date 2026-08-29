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

# Make THIS install process use the image's nvm default Node (and its npm) even
# when invoked from a non-login shell that has not sourced ~/.bashrc. The Cloud
# Agent runtime may also prepend /exec-daemon (which bundles Node 22.14) ahead of
# the nvm Node on PATH, so `nvm use default` alone is not enough — explicitly
# move the nvm default Node's bin dir to the front of PATH for this process so
# npm ci and the checks below run on it (the persistent ~/.bashrc block set up
# further down does the same for future Cloud Agent shells).
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  nvm use default >/dev/null
  nvm_node_bin="$(dirname "$(nvm which default 2>/dev/null)" 2>/dev/null || true)"
  if [ -n "$nvm_node_bin" ] && [ -x "$nvm_node_bin/node" ]; then
    case ":$PATH:" in
      *":$nvm_node_bin:"*) PATH="$nvm_node_bin:${PATH//":$nvm_node_bin:"/":"}" ;;
      *) PATH="$nvm_node_bin:$PATH" ;;
    esac
    export PATH
  fi
fi

# Require Node >= 22.18: apps/web's `node --test "lib/**/*.test.ts"` suite needs
# native TypeScript type-stripping (stabilized in Node 22.18). Fail loudly
# rather than silently running npm ci / the suites on an incompatible Node.
node_version="$(node --version 2>/dev/null || true)"
if [ -z "$node_version" ]; then
  echo "ERROR: no usable node found (nvm default missing and no node on PATH)." >&2
  exit 1
fi
node_major="${node_version#v}"; node_major="${node_major%%.*}"
node_rest="${node_version#v*.}"; node_minor="${node_rest%%.*}"
if [ "$node_major" -lt 22 ] || { [ "$node_major" -eq 22 ] && [ "$node_minor" -lt 18 ]; }; then
  echo "ERROR: Node $node_version is too old for apps/web's node --test TypeScript suites (need >= 22.18)." >&2
  echo "       Set a newer Node as the nvm default, e.g. \`nvm alias default 22\`." >&2
  exit 1
fi
echo "Using Node $node_version ($(command -v node))."

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
# Pinned to the exact version validated during this environment's setup, for
# reproducibility. Installed to /usr/local (binary lands in /usr/local/bin/deno)
# so it is on PATH for every shell without touching any shell profile. Skip the
# download only when the pinned version is already present; if a DIFFERENT
# version exists, replace it rather than silently accepting it.
DENO_VERSION="2.9.6"
current_deno=""
if command -v deno >/dev/null 2>&1; then
  current_deno="$(deno --version | head -1 | awk '{print $2}')"
fi
if [ "$current_deno" != "$DENO_VERSION" ]; then
  curl -fsSL https://deno.land/install.sh | sudo env DENO_INSTALL=/usr/local sh -s "v$DENO_VERSION"
  hash -r 2>/dev/null || true
fi
installed_deno="$(deno --version | head -1 | awk '{print $2}')"
if [ "$installed_deno" != "$DENO_VERSION" ]; then
  echo "ERROR: expected Deno $DENO_VERSION but found ${installed_deno:-none} ($(command -v deno || echo 'not on PATH'))." >&2
  exit 1
fi
echo "Using Deno $installed_deno ($(command -v deno))."

# --- Web app dependencies ----------------------------------------------------
# npm ci installs exactly what apps/web/package-lock.json pins. The default
# Cloud Agent image's nvm-managed Node (>= 22.22) satisfies the project's
# engine requirement and runs the `node --test` TypeScript suites natively.
cd "$repo_root/apps/web"
npm ci

echo "Zerro dev environment ready: apps/web deps installed, deno $(deno --version | head -1 | awk '{print $2}') available."
