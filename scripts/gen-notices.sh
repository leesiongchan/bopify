#!/usr/bin/env bash
# Writes the license texts of every Rust crate linked into the app; MIT and
# Apache both require them to ship with binary copies.
set -euo pipefail
out=${1:?usage: scripts/gen-notices.sh <absolute-output-path>}
cd "$(dirname "$0")/../rust"
cargo install cargo-about --locked --version 0.9.2 --features cli 2>/dev/null || true
cargo about generate --config about.toml --manifest-path crates/bopify-core/Cargo.toml about.hbs > "$out"
