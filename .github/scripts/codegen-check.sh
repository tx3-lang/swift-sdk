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

# Smoke-check the generated surface before compiling it: protocol identity,
# the per-transaction TIR constant, and the profile selector.
client="$OUT_DIR/generated/Sources/UnknownClient/Client.swift"
for symbol in \
  'public let PROTOCOL_NAME' \
  'public let PROTOCOL_VERSION' \
  'public let TARGET_TII_VERSION = "v1beta0"' \
  'public let TRANSFER_TIR' \
  'public enum Profile' \
  'Tx3ClientBuilder.fromParts('; do
  grep -qF "$symbol" "$client" || { echo "generated client missing: $symbol" >&2; exit 1; }
done

# Resolve the published SDK release the template pins, then edit the
# dependency to the exact checkout under test.
swift package --package-path "$OUT_DIR/generated" resolve
swift package --package-path "$OUT_DIR/generated" edit swift-sdk --path "$SDK_ROOT"
swift build --package-path "$OUT_DIR/generated" --configuration debug

mkdir -p "$OUT_DIR/consumer/Sources/GeneratedConsumer"
sed "s|__GENERATED__|$OUT_DIR/generated|g" \
  .github/scripts/generated-consumer.Package.swift \
  > "$OUT_DIR/consumer/Package.swift"
cp .github/scripts/generated-consumer.swift \
  "$OUT_DIR/consumer/Sources/GeneratedConsumer/main.swift"
swift package --package-path "$OUT_DIR/consumer" resolve
swift package --package-path "$OUT_DIR/consumer" edit swift-sdk --path "$SDK_ROOT"
swift run --package-path "$OUT_DIR/consumer" GeneratedConsumer
