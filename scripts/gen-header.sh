#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../rust"
tool=$(../scripts/release-tool.sh cbindgen)
mkdir -p ../artifacts/include
"$tool" --config cbindgen.toml --crate bopify-core --output ../artifacts/include/bopify_core.h
