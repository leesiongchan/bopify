#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/prepare-librespot.sh
export MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_TARGET_DIR="$PWD/rust/target"

# Test Connect and playback against the same lock as the shipping wrapper.
cargo test --manifest-path rust/Cargo.toml --locked --lib \
  -p bopify-core -p librespot-connect -p librespot-playback
cargo test --manifest-path rust/Cargo.toml --locked --doc \
  -p bopify-core -p librespot-connect -p librespot-playback

# Core has dev dependencies and cannot be tested as a non-member of rust/.
# --lib avoids its account/network integration test; hardware tests stay ignored.
cargo test --manifest-path .build/librespot-939dc5e/Cargo.toml --locked --lib -p librespot-core
cargo test --manifest-path .build/librespot-939dc5e/Cargo.toml --locked --doc -p librespot-core
