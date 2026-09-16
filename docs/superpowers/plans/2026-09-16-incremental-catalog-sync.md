# Incremental catalog synchronization

Preserve compatible SQLite caches across source-version changes. Compare each synchronized table's stable key and canonical content fingerprint with the live public catalog. Download only absent/changed records; update existing rows with ON CONFLICT DO UPDATE so movie relationships survive. Reconcile removals after all table indexes and changed bodies are fetched and verified. Resume partial caches through the same diff, loading parent rows before dependent records; an interrupted diff is idempotent and recomputes against committed local data.

1. Add behavioral integration tests using real SQLite and the production sync actor with a deterministic HTTP transport. Cover no-change version bump (zero body reads), insert/update/delete, independent relationship edits, restart, network failure, stale indexes, initial/partial caches and preserved movie details.
2. Add a read-only SECURITY INVOKER RPC with a fixed table allowlist. Return paged key/fingerprint metadata using canonical local-cache projections, respecting existing public-read RLS. No source rows or policies change.
3. Add matching canonical fingerprinting and table descriptions to the client. Keep the compatible cache immediately available; run diff in background and only advance completed version on successful verification. Errors keep usable old data.
4. Run integration tests, Swift core tests, Python project contracts, real anonymous RPC parity checks, advisors and signed iPhone build. Commit/push main and install/launch on 12mini.

The metadata index is not a full body download. Genuine missing records (including an earlier interrupted first download) still have to be fetched. Large content changes require the changed bodies only; no cache replacement on a source version bump.

## Additional contribution requirements

- Refresh missing-category counts on return and show fetch errors instead of stale numbers.
- Reuse full movie cards in contribution lists, with server search and pagination.
- Check new films against TMDB, IMDb, current/original titles; exact matches offer correction instead. Preserve legitimate remakes with different identifiers. Repeat the check at submission and retain server validation.
- Place a 44-point edit button below the favorite button, separated by 14 points.
- Offer start/end year fields for each story-time range, validating complete ascending ranges and supporting signed BCE years.
- Keep expired/malformed metadata files during refresh failures; show stale usable metadata and posters offline.
- Test UI on the physical 12mini only, without submitting production proposals or uninstalling the app.

## Verification

85 Swift core tests and 29 Python project/script tests passed. Real SQLite sync integration covers version-only changes with zero body downloads, exact composite-key updates without unchanged siblings, insert/update/delete, failed/incomplete responses, restart, partial caches and additive legacy migration. Client fingerprints match 70 live server samples across all seven tables. A separate code review found no remaining blockers.

Contribution RPCs use bounded explicit card projections. Automatic approval rejected adding a public whole-row movie read policy; that unapplied policy was replaced with the approved restricted RPC approach, leaving existing table RLS unchanged.

Physical UI tests are in `ReelAtlas-iOS/Tests/DeviceUI/ContributionDeviceTests.swift`. They launch the installed application by bundle ID through a standalone iOS UI-testing target. Build the runner for the physical device, then run `test-without-building`; screenshots are retained in the xcresult bundle.

Both physical 12mini UI tests passed: searched full movie cards with a reachable edit button and start/end fields, and exact duplicate detection with an existing-film correction card. The app was updated in place. Before/after copies retained all 50,005 local movie records and all 162 original movie metadata/poster cache files; favorite IDs were unchanged, and the Where cache file remained present. The existing user database was retained (iCloud restoration refreshed favorite timestamps).

Release delivery uses marketing version 1.0, build 10, with an App Store Connect upload export and automatic signing/version management.
