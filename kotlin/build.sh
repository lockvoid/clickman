#!/usr/bin/env bash
# Builds the ClickMan core for the Kotlin modules:
#
#   host     macOS arm64 cdylib → clickman/build/host/libclickman_core.dylib,
#            loaded by JNA in `./gradlew test` (jna.library.path points there).
#   android  arm64-v8a cdylib → clickman-android/src/main/jniLibs/arm64-v8a/
#            libclickman_core.so, packaged by :clickman-android.
#
# Usage: kotlin/build.sh [host|android]   (default: both)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

build_host() {
  local target=aarch64-apple-darwin
  rustup target add "$target" >/dev/null
  cargo build --manifest-path "$ROOT/Cargo.toml" -p clickman-core --release --locked --target "$target"
  mkdir -p "$HERE/clickman/build/host"
  cp "$ROOT/target/$target/release/libclickman_core.dylib" "$HERE/clickman/build/host/libclickman_core.dylib"
  echo "host: $HERE/clickman/build/host/libclickman_core.dylib"
}

build_android() {
  : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to an NDK r28 or newer}"
  rustup target add aarch64-linux-android >/dev/null
  ( cd "$ROOT" && cargo ndk -t arm64-v8a -P 26 -o "$HERE/clickman-android/src/main/jniLibs" \
      build -p clickman-core --release --locked )
  echo "android: $HERE/clickman-android/src/main/jniLibs/arm64-v8a/libclickman_core.so"
}

case "${1:-all}" in
  host) build_host ;;
  android) build_android ;;
  all) build_host; build_android ;;
  *) echo "usage: $0 [host|android]" >&2; exit 2 ;;
esac
