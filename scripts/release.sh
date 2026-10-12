#!/usr/bin/env bash
# Builds build/release/Bopify-<version>.dmg: Developer ID-signed, notarized and stapled.
# Notarizes with an App Store Connect API key when NOTARY_KEY_PATH is set (CI),
# otherwise with the notarytool keychain profile NOTARY_PROFILE (default bopify-notary).
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:?usage: scripts/release.sh <version>}
# CFBundleShortVersionString allows only numbers and dots; "0.1.0-rc.1" ships as 0.1.0.
marketing_version=${version%%-*}
build_number=${BUILD_NUMBER:-$(git rev-list --count HEAD)}
out="$PWD/build/release"
app="$out/export/Bopify.app"
dmg="$out/Bopify-$version.dmg"

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  notary_auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  notary_auth=(--keychain-profile "${NOTARY_PROFILE:-bopify-notary}")
fi

rm -rf "$out"
mkdir -p "$out/dmg"

./scripts/build-rust.sh

echo "Archiving Bopify $version ($build_number)"
xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$out/Bopify.xcarchive" \
  ARCHS=arm64 MARKETING_VERSION="$marketing_version" CURRENT_PROJECT_VERSION="$build_number" archive
xcodebuild -quiet -exportArchive -archivePath "$out/Bopify.xcarchive" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$out/export"

archs=$(lipo -archs "$app/Contents/MacOS/Bopify")
[[ "$archs" == arm64 ]] || { echo "Expected an arm64-only binary, got: $archs" >&2; exit 1; }
codesign --verify --strict --verbose=2 "$app"
# Gatekeeper and notarization need a Developer ID signature with the hardened runtime.
app_info=$(codesign -dvv "$app" 2>&1)
[[ "$app_info" == *"Authority=Developer ID Application"* ]] || { echo "App is not signed with a Developer ID Application certificate" >&2; exit 1; }
[[ "$app_info" == *"flags="*runtime* ]] || { echo "App is missing the hardened runtime flag" >&2; exit 1; }

cp -R "$app" "$out/dmg/"
ln -s /Applications "$out/dmg/Applications"
cp LICENSE "$out/dmg/LICENSE.txt"
./scripts/gen-notices.sh "$out/dmg/Third-Party Licenses.html"
hdiutil create -quiet -volname Bopify -srcfolder "$out/dmg" -format UDZO -ov "$dmg"
# Sign the DMG with the exact certificate the export used: a name match is ambiguous once a
# renewed certificate with the same name is in the keychain, a SHA-1 hash is not.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  codesign -d --extract-certificates="$out/app-cert-" "$app" 2>/dev/null
  SIGN_IDENTITY=$(shasum -a 1 "$out/app-cert-0" | cut -d' ' -f1)
fi
codesign --sign "$SIGN_IDENTITY" --timestamp "$dmg"

echo "Submitting $(basename "$dmg") for notarization"
# Parse the status rather than trusting the exit code, so a rejection always prints Apple's log.
xcrun notarytool submit "$dmg" "${notary_auth[@]}" --wait --timeout 1h --output-format json > "$out/notary.json" || true
status=$(plutil -extract status raw -o - "$out/notary.json" 2>/dev/null || echo unknown)
if [[ "$status" != Accepted ]]; then
  if id=$(plutil -extract id raw -o - "$out/notary.json" 2>/dev/null); then
    xcrun notarytool log "$id" "${notary_auth[@]}" >&2 || true
  fi
  echo "Notarization status: $status" >&2
  exit 1
fi

xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
echo "Release ready: $dmg"
