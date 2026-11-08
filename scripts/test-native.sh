#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

export CARGO_TARGET_DIR="$PWD/rust/target"

# Fails on dead code too: the crate's modules are private, so rustc reports unused items.
cargo clippy --manifest-path rust/Cargo.toml --locked -p bopify-core --all-targets -- -D warnings

cargo test --manifest-path rust/Cargo.toml --locked --lib -p bopify-core
cargo test --manifest-path rust/Cargo.toml --locked --doc -p bopify-core
