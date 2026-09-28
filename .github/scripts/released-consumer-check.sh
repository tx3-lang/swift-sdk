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

# Build and launch separately so a build failure is never retried. Hosted macOS
# runners occasionally SIGKILL a freshly signed binary at launch (exit 137);
# retry only that case, once.
swift build --package-path "$work" --product ReleasedConsumer
binary="$(swift build --package-path "$work" --show-bin-path)/ReleasedConsumer"
for attempt in 1 2; do
  status=0
  "$binary" || status=$?
  if [[ "$status" -eq 0 ]]; then
    exit 0
  fi
  if [[ "$status" -ne 137 || "$attempt" -eq 2 ]]; then
    echo "Released consumer exited with status $status" >&2
    exit "$status"
  fi
  echo "Released consumer was killed at launch (status 137); retrying once" >&2
  sleep 5
done
