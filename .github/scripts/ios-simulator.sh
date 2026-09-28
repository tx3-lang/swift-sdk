#!/usr/bin/env bash
#
# Prints the UDID of an available iOS simulator for the given model and iOS
# version, creating the device when the runner lists none.
#
# Hosted macOS runners sometimes list no simulators at job start even though
# the runtimes are installed (actions/runner-images#12948). Listing runtimes
# makes CoreSimulator rescan them; creating the device ourselves avoids
# depending on the image's preinstalled device set.
#
# Usage: ios-simulator.sh "<model>" <ios-version>   e.g. "iPhone 16 Pro" 18.5
set -euo pipefail

model="${1:?usage: ios-simulator.sh <model> <ios-version>}"
version="${2:?usage: ios-simulator.sh <model> <ios-version>}"

runtime=""
for attempt in 1 2 3 4 5 6; do
  xcrun simctl list runtimes >/dev/null
  runtime="$(xcrun simctl list runtimes --json | jq -r --arg v "$version" \
    '.runtimes[] | select(.platform == "iOS" and .version == $v and .isAvailable) | .identifier' \
    | head -n1)"
  [[ -n "$runtime" ]] && break
  echo "iOS $version runtime not listed yet (attempt $attempt); rescanning" >&2
  sleep 10
done
if [[ -z "$runtime" ]]; then
  echo "iOS $version simulator runtime is not installed on this runner" >&2
  xcrun simctl list runtimes >&2
  exit 1
fi

device_type="$(xcrun simctl list devicetypes --json | jq -r --arg m "$model" \
  '.devicetypes[] | select(.name == $m) | .identifier' | head -n1)"
if [[ -z "$device_type" ]]; then
  echo "Simulator device type '$model' is not available" >&2
  exit 1
fi

udid="$(xcrun simctl list devices --json | jq -r --arg r "$runtime" --arg m "$model" \
  '.devices[$r] // [] | map(select(.name == $m and .isAvailable)) | .[0].udid // empty')"
if [[ -z "$udid" ]]; then
  echo "Creating '$model' on $runtime" >&2
  udid="$(xcrun simctl create "$model" "$device_type" "$runtime")"
fi

echo "$udid"
