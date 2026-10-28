#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

export CARGO_TARGET_DIR="$PWD/rust/target"

# Test Connect and playback against the same lock as the shipping wrapper.
cargo test --manifest-path rust/Cargo.toml --locked --lib \
  -p bopify-core -p librespot-connect -p librespot-playback
cargo test --manifest-path rust/Cargo.toml --locked --doc \
  -p bopify-core -p librespot-connect -p librespot-playback
