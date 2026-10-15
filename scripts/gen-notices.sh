#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: scripts/gen-notices.sh <absolute-output-path>}
[[ "$out" == /* ]] || { echo "Notice output must be an absolute path." >&2; exit 1; }
tool=$("$root/scripts/release-tool.sh" cargo-about)
temporary=$(mktemp "${out}.tmp.XXXXXX")
trap 'rm -f "$temporary"' EXIT
"$tool" generate --locked --fail --config "$root/rust/about.toml" \
  --manifest-path "$root/rust/crates/bopify-core/Cargo.toml" "$root/rust/about.hbs" > "$temporary"
[[ -s "$temporary" ]] || { echo "Notice generation produced no output." >&2; exit 1; }
chmod 0644 "$temporary"
mv "$temporary" "$out"
