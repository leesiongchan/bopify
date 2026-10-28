#!/usr/bin/env bash
# Builds the Rust staticlib and packages it as an xcframework.
# Cargo cannot run as a SwiftPM plugin: plugins are sandboxed without
# network access and cargo needs both network and writes.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET=aarch64-apple-darwin            # arm64 only; for universal, build
                                       # x86_64-apple-darwin too and lipo them

echo "Link these in Package.swift (CBopifyCore linkerSettings):"
cargo rustc --release --locked --manifest-path rust/crates/bopify-core/Cargo.toml \
  --target "$TARGET" -- --print=native-static-libs
mkdir -p artifacts/include
(cd rust && mise exec -- cbindgen --config cbindgen.toml --crate bopify-core --output ../artifacts/include/bopify_core.h)

rm -rf artifacts/BopifyCoreFFI.xcframework
xcodebuild -create-xcframework \
  -library "rust/target/$TARGET/release/libbopify_core.a" \
  -headers artifacts/include \
  -output artifacts/BopifyCoreFFI.xcframework
