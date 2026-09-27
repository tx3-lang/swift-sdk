#!/usr/bin/env bash
set -euo pipefail

tag="${1:?usage: release-check.sh vMAJOR.MINOR.PATCH}"
if [[ ! "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "Release tag must match vMAJOR.MINOR.PATCH: $tag" >&2
  exit 1
fi

version="${tag#v}"
manifest_version="$(sed -n 's|^// release-version: ||p' Package.swift)"
if [[ "$version" != "$manifest_version" ]]; then
  echo "Tag $version does not match Package.swift release $manifest_version" >&2
  exit 1
fi
if [[ "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}" != "0.15" ]]; then
  echo "Tag $tag is outside the fleet 0.15 release train" >&2
  exit 1
fi
if [[ "$(git cat-file -t "$tag")" != "tag" ]]; then
  echo "Release tag $tag must be annotated" >&2
  exit 1
fi
