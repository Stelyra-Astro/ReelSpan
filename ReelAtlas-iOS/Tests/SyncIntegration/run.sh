#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_dir="$(mktemp -d /tmp/reelspan-sync-checks.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
swiftc -parse-as-library -swift-version 6 \
  "$project_root/ReelAtlas/Data/SQLiteSupport.swift" \
  "$project_root/ReelAtlas/Data/CatalogSyncSchema.swift" \
  "$project_root/ReelAtlas/Data/StoryContentSyncService.swift" \
  "$project_root/Tests/SyncIntegration/SyncChecks.swift" \
  -lsqlite3 -o "$check_dir/checks"
if [ "$#" -gt 0 ]; then
  "$check_dir/checks" "$project_root/ReelAtlas/Resources/schema.sql" "$@"
else
  "$check_dir/checks" "$project_root/ReelAtlas/Resources/schema.sql"
fi
