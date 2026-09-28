#!/usr/bin/env bash
set -euo pipefail

tag="${1:?usage: released-consumer-check.sh vMAJOR.MINOR.PATCH}"
version="${tag#v}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Sources/ReleasedConsumer"
sed "s/__VERSION__/$version/g" .github/scripts/released-consumer.Package.swift \
  > "$work/Package.swift"
cp .github/scripts/released-consumer.swift \
  "$work/Sources/ReleasedConsumer/main.swift"
swift run --package-path "$work" ReleasedConsumer
