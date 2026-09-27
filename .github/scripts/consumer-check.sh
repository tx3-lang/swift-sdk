#!/usr/bin/env bash
set -euo pipefail

SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$SCRATCH/Sources/Tx3SDKConsumer"
sed "s|path: \"../..\"|path: \"$SDK_ROOT\"|" \
  "$SDK_ROOT/examples/consumer/Package.swift" \
  > "$SCRATCH/Package.swift"
cp "$SDK_ROOT/examples/consumer/Sources/Tx3SDKConsumer/main.swift" \
  "$SCRATCH/Sources/Tx3SDKConsumer/main.swift"
swift run --package-path "$SCRATCH" Tx3SDKConsumer
