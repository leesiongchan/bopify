#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
name=${1:?usage: scripts/release-tool.sh cbindgen|cargo-about}
case "$name" in
  cbindgen) version=0.29.4 ;;
  cargo-about) version=0.9.2 ;;
  *) echo "Unsupported release tool: $name" >&2; exit 1 ;;
esac
local_bin="$root/.build/release-tools/bin/$name"
if [[ -x "$local_bin" ]] && [[ "$("$local_bin" --version)" == "$name $version" ]]; then
  printf '%s\n' "$local_bin"
elif command -v "$name" >/dev/null && [[ "$("$name" --version)" == "$name $version" ]]; then
  command -v "$name"
else
  install_options=(--locked --version "$version" --root "$root/.build/release-tools")
  if [[ "$name" == cargo-about ]]; then
    install_options+=(--features cli)
  fi
  cargo install "$name" "${install_options[@]}" >&2
  [[ -x "$local_bin" && "$("$local_bin" --version)" == "$name $version" ]] || {
    echo "Failed to install $name $version." >&2; exit 1;
  }
  printf '%s\n' "$local_bin"
fi
