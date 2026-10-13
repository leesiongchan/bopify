#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 1 ]] || { echo "Usage: scripts/release.sh <version>" >&2; exit 1; }
version=$1
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] || {
  echo "Version must have three numeric components and an optional prerelease suffix." >&2; exit 1;
}
marketing_version=${version%%-*}
build_number=${BUILD_NUMBER:-$(git rev-list --count HEAD)}
[[ "$build_number" =~ ^[1-9][0-9]{0,3}$ ]] || { echo "BUILD_NUMBER must be an integer from 1 to 9999." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit release inputs before building." >&2; exit 1; }
out="$PWD/build/release"
final="$out/Bopify-$version.dmg"
[[ ! -e "$final" && ! -L "$final" ]] || { echo "Refusing to replace an existing release: $final" >&2; exit 1; }
identity=$(python3 scripts/verify-release.py identity)
if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
  [[ -r "$NOTARY_KEY_PATH" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]] || {
    echo "Notarization API key configuration is incomplete." >&2; exit 1;
  }
  notary_auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  notary_auth=(--keychain-profile "${NOTARY_PROFILE:-bopify-notary}")
fi
mkdir -p "$out"
work=$(mktemp -d "$out/$version.XXXXXX")
app="$work/export/Bopify.app"
dmg="$work/Bopify-$version.dmg"
printf 'Release evidence: %s\n' "$work"

./scripts/build-rust.sh
resources="$PWD/Bopify/Bopify/Resources"
mkdir -p "$resources"
./scripts/gen-notices.sh "$resources/Third-Party Licenses.html"
install -m 0644 LICENSE "$resources/LICENSE.txt"

xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$work/Bopify.xcarchive" \
  ARCHS=arm64 CODE_SIGN_IDENTITY="$identity" MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number" archive
python3 - "$identity" "$work/ExportOptions.plist" <<'PYTHON'
import pathlib
import plistlib
import sys
options = plistlib.loads(pathlib.Path('scripts/ExportOptions.plist').read_bytes())
options['signingCertificate'] = sys.argv[1]
pathlib.Path(sys.argv[2]).write_bytes(plistlib.dumps(options))
PYTHON
xcodebuild -quiet -exportArchive -archivePath "$work/Bopify.xcarchive" \
  -exportOptionsPlist "$work/ExportOptions.plist" -exportPath "$work/export"
python3 scripts/verify-release.py export "$app" "$marketing_version" "$build_number" > "$work/export-check.json"
cmp "$resources/LICENSE.txt" "$app/Contents/Resources/LICENSE.txt"
cmp "$resources/Third-Party Licenses.html" "$app/Contents/Resources/Third-Party Licenses.html"

mkdir "$work/dmg"
ditto "$app" "$work/dmg/Bopify.app"
ln -s /Applications "$work/dmg/Applications"
install -m 0644 LICENSE "$work/dmg/LICENSE.txt"
install -m 0644 "$resources/Third-Party Licenses.html" "$work/dmg/Third-Party Licenses.html"
hdiutil create -quiet -volname Bopify -srcfolder "$work/dmg" -format UDZO "$dmg"
codesign --sign "$identity" --timestamp "$dmg"
codesign --verify --strict "$dmg"

if xcrun notarytool submit "$dmg" "${notary_auth[@]}" --wait --timeout 1h --output-format json > "$work/notary.json"; then
  submit_exit=0
else
  submit_exit=$?
fi
job=$(plutil -extract id raw -o - "$work/notary.json")
xcrun notarytool log "$job" "$work/notary-log.json" "${notary_auth[@]}"
if [[ "$submit_exit" != 0 ]] || ! python3 scripts/verify-release.py notary "$work/notary.json" "$work/notary-log.json" "$dmg"; then
  python3 - "$work/notary-log.json" <<'PYTHON'
import pathlib
import sys
print(pathlib.Path(sys.argv[1]).read_text(), file=sys.stderr)
PYTHON
  echo "Notarization failed; Apple log retained at $work/notary-log.json" >&2
  exit 1
fi
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

# Linking fails atomically if another run has already promoted this version.
python3 - "$dmg" "$final" <<'PY'
import os
import sys
os.link(sys.argv[1], sys.argv[2])
PY
printf 'Verified distribution artifact: %s\n' "$final"
