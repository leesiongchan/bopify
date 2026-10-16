#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# != 1 ]]; then
  echo "Usage: scripts/release.sh <version>" >&2
  exit 1
fi

version=$1
version_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$'
if [[ ! "$version" =~ $version_pattern ]]; then
  echo "Version must have three numeric components and an optional prerelease suffix." >&2
  exit 1
fi

marketing_version=${version%%-*}
build_number=${BUILD_NUMBER:-$(git rev-list --count HEAD)}
if [[ ! "$build_number" =~ ^[1-9][0-9]{0,3}$ ]]; then
  echo "BUILD_NUMBER must be an integer from 1 to 9999." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit release inputs before building." >&2
  exit 1
fi

output_dir="$PWD/build/release"
release_dmg="$output_dir/Bopify-$version.dmg"
if [[ -e "$release_dmg" || -L "$release_dmg" ]]; then
  echo "Refusing to replace an existing release: $release_dmg" >&2
  exit 1
fi

mkdir -p "$output_dir"
work_dir=$(mktemp -d "$output_dir/$version.XXXXXX")
archive_path="$work_dir/Bopify.xcarchive"
staging_dir="$work_dir/dmg"
app="$staging_dir/Bopify.app"
staged_dmg="$work_dir/Bopify-$version.dmg"
printf 'Release evidence: %s\n' "$work_dir"

./scripts/build-rust.sh

resources_dir="$PWD/Bopify/Bopify/Resources"
mkdir -p "$resources_dir"
notice_tool=$(./scripts/release-tool.sh cargo-about)
notices="$work_dir/Third-Party Licenses.html"
"$notice_tool" generate \
  --locked \
  --fail \
  --config "$PWD/rust/about.toml" \
  --manifest-path "$PWD/rust/crates/bopify-core/Cargo.toml" \
  "$PWD/rust/about.hbs" > "$notices"

if [[ ! -s "$notices" ]]; then
  echo "Notice generation produced no output." >&2
  exit 1
fi

chmod 0644 "$notices"
mv "$notices" "$resources_dir/Third-Party Licenses.html"
install -m 0644 LICENSE "$resources_dir/LICENSE.txt"

xcodebuild \
  -quiet \
  -project Bopify/Bopify.xcodeproj \
  -scheme Bopify \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  ARCHS=arm64 \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  archive

mkdir "$staging_dir"
ditto "$archive_path/Products/Applications/Bopify.app" "$app"

echo "Verifying release app signature."
codesign --verify --deep --strict "$app"
cmp "$resources_dir/LICENSE.txt" "$app/Contents/Resources/LICENSE.txt"
cmp "$resources_dir/Third-Party Licenses.html" "$app/Contents/Resources/Third-Party Licenses.html"

ln -s /Applications "$staging_dir/Applications"
install -m 0644 LICENSE "$staging_dir/LICENSE.txt"
install -m 0644 "$resources_dir/Third-Party Licenses.html" "$staging_dir/Third-Party Licenses.html"

hdiutil create \
  -quiet \
  -volname Bopify \
  -srcfolder "$staging_dir" \
  -format UDZO \
  "$staged_dmg"

codesign --sign - --timestamp=none "$staged_dmg"
codesign --verify --strict "$staged_dmg"

echo "Ad-hoc distribution: not notarized; users may need a Gatekeeper override."

# Linking fails atomically if another run has already promoted this version.
/bin/link "$staged_dmg" "$release_dmg"
printf 'Verified DMG: %s\n' "$release_dmg"
