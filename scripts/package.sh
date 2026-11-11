#!/usr/bin/env bash
# Packages dist/BotPeek.app into a drag-to-Applications DMG and a ZIP, with
# SHA-256 checksums. Notarizes and staples when Apple credentials are set:
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD
# or, on your own Mac, NOTARY_PROFILE (a profile saved with
# `xcrun notarytool store-credentials`).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-$(cat VERSION)}"
DIST="$ROOT/dist"
APP="$DIST/BotPeek.app"
NAME="BotPeek-$VERSION-macos-universal"
ZIP="$DIST/$NAME.zip"
DMG="$DIST/$NAME.dmg"

[[ -d "$APP" ]] || { echo "Build the app first: scripts/build-app.sh" >&2; exit 1; }

notarize() {
  local file="$1"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing $(basename "$file")"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait
    return 0
  fi
  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    echo "==> Notarizing $(basename "$file")"
    xcrun notarytool submit "$file" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
    return 0
  fi
  return 1
}

# Apple's ticket service often isn't ready to serve a ticket the moment
# notarization is accepted, so stapling right away can fail; retry for a while.
staple() {
  local file="$1" attempt
  for attempt in 1 2 3 4 5 6 7 8; do
    xcrun stapler staple "$file" && return 0
    echo "Stapling failed (attempt $attempt); retrying in 30s"
    sleep 30
  done
  xcrun stapler staple "$file"
}

rm -f "$ZIP" "$DMG" "$DIST/SHA256SUMS.txt"

# Notarize the app itself first (via a temporary zip) so both archives contain a stapled app.
NOTARIZED=false
if [[ -n "${APPLE_ID:-}" || -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
  notarize "$DIST/notarize.zip"
  staple "$APP"
  rm -f "$DIST/notarize.zip"
  # Fail here rather than ship an app Gatekeeper would still block.
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  NOTARIZED=true
fi

echo "==> Creating $(basename "$ZIP")"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Creating $(basename "$DMG")"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
{
  echo "Drag BotPeek into Applications, then open it from Applications."
  echo
  if [[ "$NOTARIZED" != true ]]; then
    echo "If macOS says it can't verify the developer: open System Settings → Privacy & Security,"
    echo "scroll down and click \"Open Anyway\" next to BotPeek. Do not disable Gatekeeper."
    echo
  fi
  echo "BotPeek is free, open source (MIT) and not affiliated with Grok Bot, xAI or Cursor."
  echo "https://github.com/Szewowsky/botpeek"
} > "$STAGING/Read Me First.txt"
hdiutil create -volname "BotPeek $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG"
fi
if notarize "$DMG"; then staple "$DMG"; fi

echo "==> Checksums"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" | tee SHA256SUMS.txt)
