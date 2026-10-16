#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 1 ]] || {
  echo "Usage: scripts/release.sh <version>" >&2; exit 1;
}
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
mkdir -p "$out"
work=$(mktemp -d "$out/$version.XXXXXX")
app="$work/export/Bopify.app"
dmg="$work/Bopify-$version.dmg"
printf 'Release evidence: %s\n' "$work"

./scripts/build-rust.sh
resources="$PWD/Bopify/Bopify/Resources"
mkdir -p "$resources"
notice_tool=$(./scripts/release-tool.sh cargo-about)
notices="$work/Third-Party Licenses.html"
"$notice_tool" generate --locked --fail --config "$PWD/rust/about.toml" \
  --manifest-path "$PWD/rust/crates/bopify-core/Cargo.toml" "$PWD/rust/about.hbs" > "$notices"
[[ -s "$notices" ]] || { echo "Notice generation produced no output." >&2; exit 1; }
chmod 0644 "$notices"
mv "$notices" "$resources/Third-Party Licenses.html"
install -m 0644 LICENSE "$resources/LICENSE.txt"

xcodebuild -quiet -project Bopify/Bopify.xcodeproj -scheme Bopify -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$work/Bopify.xcarchive" \
  ARCHS=arm64 CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  MARKETING_VERSION="$marketing_version" CURRENT_PROJECT_VERSION="$build_number" archive
mkdir -p "$work/export"
ditto "$work/Bopify.xcarchive/Products/Applications/Bopify.app" "$app"
python3 scripts/verify-release.py "$app" "$marketing_version" "$build_number" > "$work/export-check.json"
cmp "$resources/LICENSE.txt" "$app/Contents/Resources/LICENSE.txt"
cmp "$resources/Third-Party Licenses.html" "$app/Contents/Resources/Third-Party Licenses.html"

mkdir "$work/dmg"
ditto "$app" "$work/dmg/Bopify.app"
ln -s /Applications "$work/dmg/Applications"
install -m 0644 LICENSE "$work/dmg/LICENSE.txt"
install -m 0644 "$resources/Third-Party Licenses.html" "$work/dmg/Third-Party Licenses.html"
hdiutil create -quiet -volname Bopify -srcfolder "$work/dmg" -format UDZO "$dmg"
codesign --sign - --timestamp=none "$dmg"
codesign --verify --strict "$dmg"

echo "Ad-hoc distribution: not notarized; users may need a Gatekeeper override."

# Linking fails atomically if another run has already promoted this version.
python3 - "$dmg" "$final" <<'PY'
import os
import sys
os.link(sys.argv[1], sys.argv[2])
PY
printf 'Verified DMG: %s\n' "$final"
