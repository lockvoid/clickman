#!/usr/bin/env bash
# Builds swift/ClickManCore.xcframework from crates/clickman-core: static
# libraries for iOS devices, the iOS simulator and macOS (the macOS slice lets
# `swift test` run on the Mac host). The xcframework is a build artifact —
# rebuild it after any change to the core.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/swift/ClickManCore.xcframework"
STAGE="$ROOT/swift/.build/xcframework"
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)

for target in "${TARGETS[@]}"; do
  rustup target add "$target" >/dev/null
done

rm -rf "$OUT" "$STAGE"

# The header and module map sit in a ClickManCore/ subdirectory so they never
# collide with another static xcframework's module map in the host build.
mkdir -p "$STAGE/Headers/ClickManCore"
cp "$ROOT/crates/clickman-core/include/clickman.h" "$STAGE/Headers/ClickManCore/"
cat > "$STAGE/Headers/ClickManCore/module.modulemap" <<'EOF'
module ClickManCore {
    header "clickman.h"
    export *
}
EOF

args=()
for target in "${TARGETS[@]}"; do
  cargo build --manifest-path "$ROOT/Cargo.toml" -p clickman-core --release --locked --target "$target"
  library="$ROOT/target/$target/release/libclickman_core.a"
  # A library that defines sqlite3_* shadows the app's own SQLite for the whole app.
  symbols="$(nm -gU --no-llvm-bc "$library")"
  if grep -q ' T _sqlite3_' <<<"$symbols"; then
    echo "$library defines SQLite symbols; the core must link the system SQLite on Apple platforms" >&2
    exit 1
  fi
  args+=(-library "$library" -headers "$STAGE/Headers")
done

xcodebuild -create-xcframework "${args[@]}" -output "$OUT"
echo "built $OUT"
