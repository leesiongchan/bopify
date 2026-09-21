#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../rust"
cargo install cbindgen --locked 2>/dev/null || true
mkdir -p ../artifacts/include
cbindgen --config cbindgen.toml --crate bopify-core --output ../artifacts/include/bopify_core.h
