# Build 13 validation — 2026-09-17

Source: `ReelSpan-main-cache-count-muted-map-fixed.zip`, integrated against main `eb56111`.

## Client

- Exact discovery-page snapshots load before network refresh; legacy movie metadata is matched against local SQLite for an explicitly partial offline display.
- Cached rows/pins survive background updates and unchanged preferences; first-install bootstrap publishes the first required batch before remaining content.
- Default Map, muted base map, complete local film count and dismiss/reopen drawer behavior are included.
- Empty failure state has a manual Retry action; it bypasses cooldown, prevents duplicate taps and does not clear cached rows.
- Updated an obsolete drawer test to require explicit reopening; adapted the supplied Linux-only count runner to macOS SQLite.

## Server

Default browse uses ID-first pagination. Search uses indexed candidates and unchanged scoring; country/city filtering builds one candidate set, and details load after pagination. Bound dynamic SQL uses typed parameters, not interpolated user input. Candidate lookups prevent inflated estimates from forcing full-table joins.

The private text projection is inaccessible to client roles and maintained by a restricted trigger. Trigram handles longer terms; literal character/pair indexes handle short terms. Anonymous SQL timeout is 5 seconds; this is a fallback, not proof of performance.

An attempted four-column generated-column rewrite was cancelled before commit after it proved too costly and briefly caused schema-cache 503 responses. The committed ranked-scope migration avoids that rewrite. The subsequent private projection creates a separate table without rewriting the original movies table. Final migration replay order is checked explicitly.

## Evidence so far

- Swift: 92 tests, zero failures (fresh pre-commit rerun).
- Python: 68 tests passed.
- Sync integration: all fixture scenarios passed, including failed/incomplete responses and first required parent batch.
- Exact local count: five checks passed.
- Simulator build: `BUILD SUCCEEDED`.
- Release archive: `ARCHIVE SUCCEEDED`, 1.0 (13), `com.xiaoguiwk.ReelSpan`, Team `KCC8FFFAA5`.
- Final archive: `ReelSpan-Build-13-final.xcarchive`; original signing verified through system keychain. App/dSYM UUID: `2C134787-99B6-3DFE-925E-D4C9E9BE828C` (arm64).

Independent review found and corrected first-page pagination recovery and Map retry coverage. Client tests/build are passing; production search performance is NOT fully repaired. The anonymous regression run matched all nine captured full-JSON cases, then passed literal/Chinese cases but failed the high-frequency `war` stress query with HTTP 500 / SQLSTATE 57014. A subsequent repeat saw live metadata changes invalidate the static New York snapshot; future parity must compare the old and new implementation against the same current database snapshot, not silently update expected results.

Field-level trigram indexes were subsequently deployed (`discover_field_rank_indexes`, remote version `20260917035304`), but the proposed adaptive field plan still measured 8.429 seconds for a high-frequency input. Large cast text rechecks dominated. This is diagnostic evidence, not a passing performance result for the live RPC.

The generic overlapping-chunk redesign was not deployed: production write-lock/backfill risk was rejected by safety review; the user paused further Supabase changes. Both drafts are outside `supabase/migrations/`, under `docs/supabase/drafts/`, to prevent accidental deployment. Details: `docs/diagnostics/2026-09-17-supabase-search-status.md`.

## Upload

After source commit `a22ac97` was pushed to main, the final archive was uploaded with explicit App Store Connect API credentials using `xcodebuild -exportArchive` and `manageAppVersionAndBuildNumber=false`. At 2026-09-17 12:26:11 Asia/Shanghai the command exited 0 and logged `Upload succeeded` / `EXPORT SUCCEEDED`; the package was processing. No review was submitted. Processing completion / TestFlight readiness must be verified separately.

Export logs identify Store profile UUID `64e37f7e-6f7b-4d25-8f54-85da305b7b2a` and `Apple Distribution: KUN WANG (KCC8FFFAA5)`, certificate SHA-1 `249EEAAC5AAFAABD58871E60E063F9C3E367704C`, consistent with the verified managed-signing chain.

Raw logs and artifacts remain ignored under `Artifacts/silent-refresh-validation/build13/`. Automated tests do not substitute for real-device upgrade/offline UI acceptance; that remains a separate validation step. No App Store review submission is authorized.
