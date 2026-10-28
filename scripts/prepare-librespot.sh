#!/usr/bin/env bash
# Keep the occurrence-selection patch reproducible without altering Cargo's cache.
set -euo pipefail
cd "$(dirname "$0")/.."
revision=939dc5ee9d833e1980f9495241219d9d4868a061
source_dir="$PWD/.build/librespot-939dc5e"
patch_file="$PWD/rust/patches/librespot-queue-selection.patch"
if [[ ! -e "$source_dir" ]]; then
  mkdir -p .build
  git clone https://github.com/librespot-org/librespot.git "$source_dir"
  git -C "$source_dir" checkout --detach "$revision"
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$revision" ]] || {
  echo "Unexpected librespot revision; leaving the checkout untouched." >&2; exit 1;
}
[[ -z "$(git -C "$source_dir" ls-files --others --exclude-standard)" ]] || {
  echo "Untracked files in librespot checkout; leaving it untouched." >&2; exit 1;
}
if git -C "$source_dir" diff --quiet HEAD; then
  git -C "$source_dir" apply --check "$patch_file"
  git -C "$source_dir" apply --index "$patch_file"
fi
actual_patch=$(mktemp)
trap 'rm -f "$actual_patch"' EXIT
# Match the checked-in patch's algorithm regardless of the runner's Git config.
git -C "$source_dir" diff --no-ext-diff --binary --default-prefix --diff-algorithm=histogram HEAD > "$actual_patch"
cmp -s "$patch_file" "$actual_patch" || {
  echo "Unexpected librespot modifications; leaving the checkout untouched." >&2; exit 1;
}
git -C "$source_dir" apply --reverse --check "$patch_file"
echo "Pinned librespot queue patch verified."
