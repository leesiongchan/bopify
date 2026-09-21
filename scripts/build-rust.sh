#!/usr/bin/env bash
# Builds the Rust staticlib and packages it as an xcframework.
# Cargo cannot run as a SwiftPM plugin: plugins are sandboxed without
# network access and cargo needs both network and writes.
set -euo pipefail
cd "$(dirname "$0")/.."

export MACOSX_DEPLOYMENT_TARGET=14.0   # must match the Xcode target
TARGET=aarch64-apple-darwin            # arm64 only; for universal, build
                                       # x86_64-apple-darwin too and lipo them

cargo build --release --manifest-path rust/Cargo.toml --target "$TARGET"
./scripts/gen-header.sh

rm -rf artifacts/BopifyCoreFFI.xcframework
xcodebuild -create-xcframework \
  -library "rust/target/$TARGET/release/libbopify_core.a" \
  -headers artifacts/include \
  -output artifacts/BopifyCoreFFI.xcframework

echo "Link these in Package.swift (CBopifyCore linkerSettings):"
cargo rustc --release --manifest-path rust/crates/bopify-core/Cargo.toml \
  --target "$TARGET" -- --print=native-static-libs 2>&1 | grep native-static-libs || true
