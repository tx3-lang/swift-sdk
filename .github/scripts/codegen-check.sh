#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="$(pwd)"
OUT_DIR="$(mktemp -d)"
TX3C="${TX3C:-tx3c}"
trap 'rm -rf "$OUT_DIR"' EXIT

"$TX3C" codegen \
  --tii Tests/Tx3SDKTests/Fixtures/transfer.tii \
  --template swift-client \
  --output "$OUT_DIR/generated"

# SwiftPM resolves the generated package's 0.15.0 lower bound before `edit`.
# Supply that unreleased tag through a temporary local mirror, then edit the
# dependency to the exact checkout under test.
git clone --quiet "$SDK_ROOT" "$OUT_DIR/swift-sdk"
git -C "$OUT_DIR/swift-sdk" tag 0.15.0
swift package --package-path "$OUT_DIR/generated" config set-mirror \
  --original https://github.com/tx3-lang/swift-sdk.git \
  --mirror "file://$OUT_DIR/swift-sdk"
swift package --package-path "$OUT_DIR/generated" resolve
swift package --package-path "$OUT_DIR/generated" edit swift-sdk --path "$SDK_ROOT"
swift build --package-path "$OUT_DIR/generated" --configuration debug

mkdir -p "$OUT_DIR/consumer/Sources/GeneratedConsumer"
sed "s|__GENERATED__|$OUT_DIR/generated|g" \
  .github/scripts/generated-consumer.Package.swift \
  > "$OUT_DIR/consumer/Package.swift"
cp .github/scripts/generated-consumer.swift \
  "$OUT_DIR/consumer/Sources/GeneratedConsumer/main.swift"
swift package --package-path "$OUT_DIR/consumer" config set-mirror \
  --original https://github.com/tx3-lang/swift-sdk.git \
  --mirror "file://$OUT_DIR/swift-sdk"
swift package --package-path "$OUT_DIR/consumer" resolve
swift package --package-path "$OUT_DIR/consumer" edit swift-sdk --path "$SDK_ROOT"
swift run --package-path "$OUT_DIR/consumer" GeneratedConsumer
