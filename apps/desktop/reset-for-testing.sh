#!/usr/bin/env bash
#
# reset-for-testing.sh — wipe all local Zerro state so the next launch
# behaves like a brand-new user (permissions, trial, prefs, caches, keychain).
#
# Bundle ID: com.cbreeding.Zerro  |  App is NOT sandboxed (data lives in ~/Library/*)
#
# NOTE: Keychain items (trial token/email, BYOK license, API keys) are
# intentionally built to persist across delete+reinstall. This script deletes
# them explicitly — that's the only way to get a true "new user" trial state.
#
# Usage:  bash reset-for-testing.sh
#         bash reset-for-testing.sh --delete-app   # also removes /Applications/Zerro.app
set -uo pipefail

BUNDLE_ID="com.cbreeding.Zerro"
APP_NAME="Zerro"
DELETE_APP=false
[[ "${1:-}" == "--delete-app" ]] && DELETE_APP=true

echo "==> Quitting $APP_NAME"
osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null
pkill -x "$APP_NAME" 2>/dev/null
sleep 1

echo "==> Resetting TCC permissions (Screen Recording, Microphone, Accessibility)"
# 'All' covers everything granted to this bundle id; the individual lines are
# listed too in case you want to reset selectively.
tccutil reset All "$BUNDLE_ID" 2>/dev/null
# tccutil reset ScreenCapture "$BUNDLE_ID"
# tccutil reset Microphone   "$BUNDLE_ID"
# tccutil reset Accessibility "$BUNDLE_ID"

echo "==> Removing application support / caches / prefs / logs / state"
rm -rf \
  "$HOME/Library/Application Support/$APP_NAME" \
  "$HOME/Library/Caches/$BUNDLE_ID" \
  "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
  "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies" \
  "$HOME/Library/WebKit/$BUNDLE_ID" \
  "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
  "$HOME/Library/Logs/$APP_NAME" \
  "$HOME/Library/Preferences/$BUNDLE_ID.plist"

echo "==> Clearing UserDefaults + flushing the prefs daemon cache"
# The blanket delete covers every vf.* key, including one-time flags like
# vf.areaSelector.toolbarWalkthroughSeen — so the first-run toolbar
# walkthrough re-arms on the next overlay open after a reset. It also wipes
# the What's New pair (vf.whatsNew.showOnUpdate + vf.whatsNew.lastSeenVersion),
# which makes the next launch a "fresh install" (marker seeded silently, no
# pop). To re-trigger the update auto-pop instead, set the marker to an older
# version:  defaults write "$BUNDLE_ID" vf.whatsNew.lastSeenVersion 1.0.0
defaults delete "$BUNDLE_ID" 2>/dev/null
killall cfprefsd 2>/dev/null   # otherwise cfprefsd can rewrite the deleted plist

echo "==> Deleting Keychain items (these survive reinstall by design)"
for acct in \
  openai_api_key gemini_api_key anthropic_api_key \
  byok_license_key byok_instance_id byok_last_validated byok_license_created_at \
  license_product_kind trial_email trial_token
do
  security delete-generic-password -s "$BUNDLE_ID" -a "$acct" >/dev/null 2>&1 \
    && echo "    deleted: $acct"
done

if $DELETE_APP; then
  echo "==> Removing /Applications/$APP_NAME.app"
  rm -rf "/Applications/$APP_NAME.app"
fi

echo ""
echo "Done. Next launch should behave as a fresh install."
echo "If you tested a DEBUG (Xcode) build, also wipe DerivedData:"
echo "  rm -rf ~/Library/Developer/Xcode/DerivedData/Zerro-*"
