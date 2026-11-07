#!/usr/bin/env bash
# Verify the actual signed app's desktop security model and fresh Soloist installation.
set -euo pipefail

if [[ $# != 1 || ! -d "$1/Contents/MacOS" ]]; then
  echo "Usage: scripts/verify-desktop-app.sh /path/to/Bopify.app" >&2
  exit 1
fi

app=$1
evidence=$(mktemp -d "${TMPDIR:-/tmp}/bopify-desktop-check.XXXXXX")
trap 'rm -rf "$evidence"' EXIT
codesign --verify --deep --strict "$app"
codesign --display --entitlements - --xml "$app" > "$evidence/entitlements.plist" 2> "$evidence/signature.txt"
display=$(<"$evidence/signature.txt")
case "$display" in
  *"invalid entitlements"*) echo "Unable to read effective app entitlements." >&2; exit 1 ;;
esac
codesign --display --verbose=4 "$app" 2> "$evidence/details.txt"
details=$(<"$evidence/details.txt")
if [[ ! "$details" =~ flags=0x([[:xdigit:]]+) ]]; then
  echo "Unable to read code-signing flags." >&2
  exit 1
fi
# CS_RUNTIME is bit16; ad-hoc signing adds other flags to the same field.
flags=${BASH_REMATCH[1]}
if (( (16#$flags & 0x10000) == 0 )); then
  echo "App lacks hardened runtime." >&2
  exit 1
fi
if [[ -s "$evidence/entitlements.plist" ]]; then
  plutil -lint "$evidence/entitlements.plist" >/dev/null
  for entitlement in com.apple.security.app-sandbox com.apple.security.files.bookmarks.app-scope com.apple.security.files.user-selected.executable; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$evidence/entitlements.plist" 2>/dev/null) || value=absent
    if [[ "$value" == true ]]; then
      echo "Unexpected sandbox capability: $entitlement" >&2
      exit 1
    fi
  done
fi
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
binary="$app/Contents/MacOS/$executable"
if [[ $(lipo -archs "$binary") != arm64 ]]; then
  echo "Expected the supported arm64 app." >&2
  exit 1
fi
echo "Verified signature, hardened runtime, arm64, and absence of sandbox capabilities."
"$binary" --verify-soloist-installation
