#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_dir="$(mktemp -d /tmp/reelspan-count-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -swift-version 6 \
  "$project_root/ReelAtlas/Data/SQLiteSupport.swift" \
  "$project_root/ReelAtlas/Data/LocalFilmCountStore.swift" \
  "$project_root/Tests/SyncIntegration/LocalCountChecks.swift" \
  -lsqlite3 -o "$check_dir/checks"
"$check_dir/checks"
