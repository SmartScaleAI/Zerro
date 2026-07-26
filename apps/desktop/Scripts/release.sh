#!/usr/bin/env bash
#
# release.sh — Phase 1 local release script for Zerro (Sparkle, direct download)
#
# Builds, signs (Developer ID), notarizes, staples, packages a .dmg, and
# regenerates the signed Sparkle appcast — all locally so you can debug the
# fiddly bits (notarization!) fast. It deliberately STOPS before uploading;
# it prints the exact files to publish and the git tag command to run.
#
# Usage:
#   ./Scripts/release.sh <marketing_version> <build_number>
#   ./Scripts/release.sh 1.0.2 3
#
#   <marketing_version>  human version, e.g. 1.0.2  -> MARKETING_VERSION
#   <build_number>       integer Sparkle compares,  -> CURRENT_PROJECT_VERSION
#                        MUST be higher than the last shipped build (currently 2).
#
# Prereqs (see Scripts/README-release.md for full setup):
#   - Xcode + command line tools
#   - A notarytool keychain profile named "$NOTARY_PROFILE" (one-time setup)
#   - Sparkle CLI tools (generate_appcast, sign_update) at "$SPARKLE_BIN"
#   - Your Sparkle EdDSA private key in the login keychain (already there)
#
# This script is intentionally verbose and fails fast. Read what it prints.

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Project configuration — derived from the Zerro Xcode project. Change only if
# the project changes.
# ----------------------------------------------------------------------------
SCHEME="Zerro"
CONFIGURATION="Release"
APP_NAME="Zerro"
BUNDLE_ID="com.cbreeding.Zerro"
TEAM_ID="H6NWCRRAHV"

# Notary credentials: a keychain profile created once with
#   xcrun notarytool store-credentials "Zerro-Notary" \
#       --key /path/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
# (App Store Connect API key — the recommended auth method.)
NOTARY_PROFILE="${NOTARY_PROFILE:-Zerro-Notary}"

# The download URL your appcast points users at. Your shipped app's SUFeedURL is
# https://getzerro.app/appcast.xml and the current enclosure is
# https://getzerro.app/Zerro.dmg — keep this consistent with what you serve.
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://getzerro.app/}"
# "Find out more" link shown if the user must update manually.
APPCAST_LINK="${APPCAST_LINK:-https://getzerro.app/}"

# ----------------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------------
# Resolve repo root from this script's location (Scripts/release.sh -> repo).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT="$REPO_ROOT/$APP_NAME.xcodeproj"
EXPORT_PLIST="$SCRIPT_DIR/ExportOptions.plist"

# Sparkle CLI tools. Default: committed under Scripts/sparkle/bin. Override with
# SPARKLE_BIN env var if you keep them elsewhere.
SPARKLE_BIN="${SPARKLE_BIN:-$SCRIPT_DIR/sparkle/bin}"

# Build outputs (gitignored via dist/).
BUILD_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
# generate_appcast scans this folder for archives and writes appcast.xml here.
APPCAST_DIR="$BUILD_DIR"
APPCAST_PATH="$APPCAST_DIR/appcast.xml"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
c_bold=$'\033[1m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_rst=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_bold" "$*" "$c_rst"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s    ✓ %s%s\n' "$c_grn" "$*" "$c_rst"; }
warn() { printf '%s    ! %s%s\n' "$c_ylw" "$*" "$c_rst"; }
die()  { printf '%s\nERROR: %s%s\n' "$c_red" "$*" "$c_rst" >&2; exit 1; }

trap 'die "Failed at line $LINENO. See output above."' ERR

# ----------------------------------------------------------------------------
# Argument parsing & validation
# ----------------------------------------------------------------------------
[[ $# -eq 2 ]] || die "Usage: $0 <marketing_version> <build_number>   e.g. $0 1.0.2 3"
MARKETING_VERSION="$1"
BUILD_NUMBER="$2"

[[ "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
  || die "marketing_version '$MARKETING_VERSION' should look like 1.0.2"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] \
  || die "build_number '$BUILD_NUMBER' must be a positive integer"

# ----------------------------------------------------------------------------
# Preflight checks (fail before doing slow work)
# ----------------------------------------------------------------------------
step "Preflight checks"

command -v xcodebuild >/dev/null || die "xcodebuild not found. Install Xcode."
command -v xcrun >/dev/null      || die "xcrun not found."
command -v hdiutil >/dev/null    || die "hdiutil not found."
[[ -d "$PROJECT" ]]              || die "Xcode project not found at $PROJECT"
[[ -f "$EXPORT_PLIST" ]]        || die "ExportOptions.plist not found at $EXPORT_PLIST"
[[ -x "$SPARKLE_BIN/generate_appcast" ]] \
  || die "Sparkle's generate_appcast not found/executable at $SPARKLE_BIN. See Scripts/README-release.md."

# Confirm a Developer ID Application identity is present in the keychain.
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  die "No 'Developer ID Application' signing identity in your keychain. Import your cert + key (.p12)."
fi
ok "Developer ID Application identity present"

# Confirm the notary profile exists (catches the #1 first-run mistake).
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  die "notarytool profile '$NOTARY_PROFILE' not set up. Run:
    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
        --key /path/to/AuthKey_XXXXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>"
fi
ok "notarytool profile '$NOTARY_PROFILE' is usable"

# Guard against re-using/lowering the build number. agvtool must run from the
# directory containing the .xcodeproj.
LAST_BUILD="$(cd "$REPO_ROOT" && xcrun agvtool what-version -terse 2>/dev/null || echo 0)"
if [[ "$LAST_BUILD" =~ ^[0-9]+$ ]] && (( BUILD_NUMBER <= LAST_BUILD )); then
  die "build_number $BUILD_NUMBER is not greater than current ($LAST_BUILD). Sparkle would not offer the update."
fi
ok "build_number $BUILD_NUMBER > current $LAST_BUILD"

# The version must have a What's New entry in Changelog.swift, or the in-app
# pop silently skips this release (same gate CI runs; see docs/DEPLOY-RUNBOOK.md
# step 6). Intentional internal-only release: ZERRO_ALLOW_NO_CHANGELOG=1.
python3 "$SCRIPT_DIR/check_changelog_entry.py" --version "$MARKETING_VERSION" \
  || die "No What's New entry for $MARKETING_VERSION in Changelog.swift (set ZERRO_ALLOW_NO_CHANGELOG=1 to skip intentionally)."
ok "Changelog.swift has a What's New entry for $MARKETING_VERSION"

info "Releasing $APP_NAME $MARKETING_VERSION (build $BUILD_NUMBER)"

# ----------------------------------------------------------------------------
# 1. Bump versions in the project
# ----------------------------------------------------------------------------
step "Bumping version → $MARKETING_VERSION (build $BUILD_NUMBER)"
( cd "$REPO_ROOT"
  xcrun agvtool new-version -all "$BUILD_NUMBER" >/dev/null
  xcrun agvtool new-marketing-version "$MARKETING_VERSION" >/dev/null
)
ok "Project version set (CURRENT_PROJECT_VERSION=$BUILD_NUMBER, MARKETING_VERSION=$MARKETING_VERSION)"
warn "agvtool edited project.pbxproj — commit that change as part of this release."

# ----------------------------------------------------------------------------
# 2. Clean & archive
# ----------------------------------------------------------------------------
step "Archiving (this can take a few minutes)"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$DMG_PATH"
mkdir -p "$BUILD_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID"
ok "Archive created at $ARCHIVE_PATH"

# ----------------------------------------------------------------------------
# 3. Export a Developer ID-signed .app
# ----------------------------------------------------------------------------
step "Exporting Developer ID app"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST"
[[ -d "$APP_PATH" ]] || die "Export did not produce $APP_PATH"
ok "Exported $APP_PATH"

# Sanity: confirm it's signed Developer ID + hardened runtime.
step "Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvvv "$APP_PATH" 2>&1 | grep -q "flags=.*runtime" \
  || die "Hardened runtime not enabled on the exported app — notarization will reject it."
ok "Signature valid and hardened runtime enabled"

# ----------------------------------------------------------------------------
# 4. Package into a .dmg
# ----------------------------------------------------------------------------
# We notarize the .dmg (notarytool accepts dmg/zip/pkg). A simple read-only,
# compressed dmg is fine for Sparkle. (You can swap in create-dmg later for a
# prettier background/Applications symlink.)
step "Building .dmg"
DMG_STAGE="$(mktemp -d)"
cp -R "$APP_PATH" "$DMG_STAGE/"
# Optional: a drag-to-Applications affordance for manual installs.
ln -s /Applications "$DMG_STAGE/Applications" || true
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO \
  "$DMG_PATH" >/dev/null
rm -rf "$DMG_STAGE"
[[ -f "$DMG_PATH" ]] || die "DMG was not created at $DMG_PATH"
ok "Created $DMG_PATH"

# Sign the dmg itself (good hygiene; notarization works either way).
codesign --force --sign "Developer ID Application" --timestamp "$DMG_PATH"
ok "Signed the dmg"

# ----------------------------------------------------------------------------
# 5. Notarize + staple
# ----------------------------------------------------------------------------
step "Submitting to Apple notary service (waits for result)"
# --wait blocks until Apple finishes. On rejection we dump the log so you can
# see exactly which binary/entitlement failed.
if ! xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait; then
  warn "Notarization failed. Fetching the latest submission log…"
  SUB_ID="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>/dev/null \
            | awk '/id:/ {print $2; exit}')"
  [[ -n "${SUB_ID:-}" ]] && xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" || true
  die "Notarization rejected. Fix the issues above (commonly: unsigned nested binary, missing hardened runtime, bad entitlement) and re-run."
fi
ok "Notarization accepted"

step "Stapling the ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
ok "Stapled and validated the dmg"

# Gatekeeper assessment of the app inside (mount, check, unmount).
step "Gatekeeper check (spctl)"
MNT="$(mktemp -d)"
hdiutil attach "$DMG_PATH" -nobrowse -mountpoint "$MNT" >/dev/null
if spctl -a -vvv -t install "$MNT/$APP_NAME.app" 2>&1 | grep -q "accepted"; then
  ok "spctl: accepted (Gatekeeper will allow this app)"
else
  warn "spctl did not report 'accepted' — inspect manually before publishing."
fi
hdiutil detach "$MNT" >/dev/null || true
rm -rf "$MNT"

# ----------------------------------------------------------------------------
# 6. Generate the signed appcast
# ----------------------------------------------------------------------------
# generate_appcast scans APPCAST_DIR for update archives (our .dmg), computes
# the EdDSA signature using your Sparkle private key (from the login keychain),
# fills in length/version, and writes appcast.xml. It reads the version/build
# straight from the app inside the dmg.
step "Generating signed appcast"
# Keep only THIS release's dmg in the scan folder so old artifacts don't get
# re-added with stale URLs. (Archive old dmgs elsewhere if you want delta updates.)
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --link "$APPCAST_LINK" \
  -o "$APPCAST_PATH" \
  "$APPCAST_DIR"
[[ -f "$APPCAST_PATH" ]] || die "generate_appcast did not write $APPCAST_PATH"
ok "Wrote $APPCAST_PATH"
info "Appcast preview:"
sed 's/^/      /' "$APPCAST_PATH"

# ----------------------------------------------------------------------------
# 7. Done — print publish instructions (intentionally NOT automated in Phase 1)
# ----------------------------------------------------------------------------
step "Release built successfully — finish publishing manually"
cat <<EOF

  ${c_bold}Artifacts ready in dist/:${c_rst}
    • $DMG_PATH
    • $APPCAST_PATH

  ${c_bold}Next steps (you do these):${c_rst}

  1. TEST the update path first:
       - Install the previously-shipped build (lower build number).
       - Temporarily host the new dmg + appcast somewhere (or a staging path).
       - In the app: "Check for Updates…" → confirm it finds, verifies, installs.

  2. PUBLISH to getzerro.app so these URLs serve the new files:
       ${DOWNLOAD_URL_PREFIX}$APP_NAME.dmg
       ${DOWNLOAD_URL_PREFIX}appcast.xml
     (Upload via your site repo / Vercel deploy — whatever serves getzerro.app.)

  3. COMMIT the version bump and TAG the release:
       git add -A
       git commit -m "Release $MARKETING_VERSION (build $BUILD_NUMBER)"
       git tag v$MARKETING_VERSION
       git push && git push --tags

  ${c_ylw}Reminder:${c_rst} the appcast was signed with your Sparkle EdDSA key. If a test
  client reports a signature mismatch, the app was built with a different key
  than the one in your keychain — back up / reconcile your Sparkle private key.

EOF
ok "All done."
