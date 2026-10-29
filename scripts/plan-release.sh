#!/usr/bin/env bash
# Decides whether HEAD is a release and writes its notes; results go to $GITHUB_OUTPUT.
set -euo pipefail

if [[ $# != 1 ]]; then
  echo "Usage: scripts/plan-release.sh <notes-path>" >&2
  exit 1
fi

notes_path=$1
# --bumped-version alone drops tags on commits outside include_paths; --unreleased keeps them.
cliff=(git-cliff --offline --unreleased --bump)
plan=$("${cliff[@]}" --body '{{ commits | length }} {{ version }}')
read -r count tag <<< "$plan"
if [[ $count == 0 ]]; then
  echo "No user-facing app changes since $tag; skipping release."
  echo "release=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

mkdir -p "$(dirname "$notes_path")"
"${cliff[@]}" --output "$notes_path"
echo "Prepared $tag from $count user-facing commits ($(($(wc -c < "$notes_path"))) bytes of notes)."
printf 'release=true\ntag=%s\nversion=%s\n' "$tag" "${tag#v}" >> "$GITHUB_OUTPUT"
