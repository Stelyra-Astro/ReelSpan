# Supabase-First Branch Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge the two ReelSpan feature branches and deliver Supabase-first movie metadata, Worker fallback, correct native-detail routing, filtered search, stable 15-item paging, weighted ranking, and persistent device cache.

**Architecture:** Keep Supabase story synchronization and local SQLite from `codex/supabase-content-sync`. Port dynamic metadata/cache/UI from `codex/dynamic-metadata`, but change detail reads to device cache → Supabase `movies.payload` → Worker fallback. Add a compact Supabase ranking view so local location/time candidates can be weighted before pagination without downloading full movie payloads.

**Tech Stack:** Swift 6, SwiftUI, MapKit, SQLite3, URLSession, StoreKit 2, Supabase PostgREST, Cloudflare Worker, XCTest, Python unittest.

**Spec:** `docs/superpowers/specs/2026-09-15-supabase-first-branch-merge-design.md`

## Global Constraints

- iOS 17 minimum.
- Worker host: `https://tmdb.xiaoguiwk.top`.
- Supabase project: `injisguyqfxfwgnbtghe` using the existing publishable key only.
- Metadata/image device cache: 30 days, 150 MiB combined.
- Search suggestions: places first, movies second, maximum 10 combined.
- Drawer page size: 15.
- Movie search results absent from local `story_movies` are hidden.
- IMDb opens only from native `MovieDetailView`.

---

### Task 1: Merge Core Dynamic Metadata Files

**Files:**
- Create/merge: `ReelAtlas/Core/MovieCachePolicy.swift`
- Create/merge: `ReelAtlas/Core/MovieMetadataModels.swift`
- Create/merge: `ReelAtlas/Core/MovieMetadataRequest.swift`
- Create/merge: `ReelAtlas/Core/MovieMetadataCache.swift`
- Create/merge: `ReelAtlas/Core/MovieMetadataService.swift`
- Create/merge: `ReelAtlas/Core/MovieMetadataStore.swift`
- Create/merge: `ReelAtlas/Core/SearchAndTip.swift`
- Test: `Tests/ReelAtlasCoreTests/CoreRulesTests.swift`
- Test: `Tests/ReelAtlasCoreTests/SearchAndTipTests.swift`

**Interfaces:**
- Produces `MovieMetadataService.metadata(tmdbID:)`, `MovieMetadataStore`, `LatestMovieSearch`, `MoviePaginationPolicy`.

- [ ] Write failing tests for request construction, cache behavior, and search policy.
- [ ] Run `swift test` and confirm failures are due to missing dynamic files/types.
- [ ] Port the dynamic core files and keep `https://tmdb.xiaoguiwk.top`.
- [ ] Run `swift test` until the dynamic core tests pass.

### Task 2: Implement Supabase-First Detail Resolution

**Files:**
- Modify: `ReelAtlas/Core/MovieMetadataRequest.swift`
- Modify: `ReelAtlas/Core/MovieMetadataService.swift`
- Test: `Tests/ReelAtlasCoreTests/CoreRulesTests.swift`

**Interfaces:**
- `MovieMetadataRequest.supabaseDetail(tmdbID:)` requests `public.movies?tmdb_id=eq...&select=payload&limit=1` with publishable `apikey`.
- `MovieMetadataService.metadata(tmdbID:)` resolves local cache → Supabase → Worker.

- [ ] Add tests proving cache is preferred, a Supabase payload hit avoids Worker, an empty Supabase result falls back to Worker, and Supabase failure falls back without surfacing until Worker also fails.
- [ ] Run targeted tests and confirm red failures.
- [ ] Implement Supabase request/decoding and fallback while preserving request de-duplication/cancellation.
- [ ] Re-run targeted and full Swift tests.

### Task 3: Add Compact Ranking API and Candidate Ranking

**Files:**
- Create: `../supabase/migrations/20260915150000_add_movie_rankings_view.sql`
- Modify: `ReelAtlas/Core/RankingCalculator.swift`
- Modify: `ReelAtlas/Core/MovieMetadataRequest.swift`
- Modify: `ReelAtlas/Core/MovieMetadataService.swift`
- Modify: `ReelAtlas/Data/ContentRepository.swift`
- Test: `Tests/ReelAtlasCoreTests/CoreRulesTests.swift`

**Interfaces:**
- `MovieRanking` contains `tmdbID`, `rating`, `voteCount`, and computed Bayesian score.
- `MovieMetadataService.rankings(tmdbIDs:)` bulk-loads compact Supabase ranking rows.
- `ContentRepository.candidateMovies(...)` returns stable local candidates before network ranking.

- [ ] Add tests for Bayesian constants/tie behavior and ranking request batching/decoding.
- [ ] Confirm tests fail.
- [ ] Add the `movie_rankings` security-invoker view and read grant.
- [ ] Implement ranking fetch and stable candidate sorting fallback.
- [ ] Run full Swift tests.

### Task 4: Merge Story Bootstrap with Pagination/Search Workers

**Files:**
- Modify: `ReelAtlas/App/AppModel.swift`
- Modify: `ReelAtlas/Data/ContentRepository.swift`
- Preserve: `ReelAtlas/Data/StoryContentSyncService.swift`
- Modify: `ReelAtlas/Data/AppModels.swift`

**Interfaces:**
- Cold launch always calls `StoryContentSyncService.ensureCurrentContent()` before initial location release.
- `AppModel.loadMoreMovies()` appends 15 ranked results.
- `AppModel.searchMovies(_:)` returns only Worker results with a local `tmdb_id` match.

- [ ] Add/adjust core model tests for local-only search result mapping and page size.
- [ ] Verify red failures.
- [ ] Merge AppModel bootstrap gate, pagination state, metadata store, and actor workers.
- [ ] Ensure search workers open the current synchronized SQLite path, not a bundled seed.
- [ ] Run tests/static compile checks.

### Task 5: Restore Native Detail and Correct Drawer/Search UI

**Files:**
- Modify: `ReelAtlas/Features/Home/HomeView.swift`
- Modify: `ReelAtlas/Features/Home/MovieRowView.swift`
- Modify: `ReelAtlas/Features/Home/LocalPosterView.swift`
- Modify: `ReelAtlas/Features/MovieDetail/MovieDetailView.swift`
- Modify: `ReelAtlas/Data/UserDatabase.swift`
- Modify: `ReelAtlas/Services/PurchaseManager.swift`

**Interfaces:**
- Drawer/search/favorites route to `MovieDetailView`.
- Search suggestions are places first, movies second, max 10.
- `LocalPosterView` reads through persistent movie image cache.

- [ ] Add policy tests for suggestion ordering/limit and local-only movie search.
- [ ] Port UI behavior from dynamic branch while retaining Supabase loading state and map marker safety.
- [ ] Remove Safari-as-detail routing; preserve IMDb link inside detail.
- [ ] Keep Tip feature and StoreKit additions from the dynamic branch.
- [ ] Run Swift tests and source scans.

### Task 6: Merge Xcode Project/Resources and Remove Obsolete Paths

**Files:**
- Modify: `ReelSpan.xcodeproj/project.pbxproj`
- Modify: `ReelSpan.xcodeproj/xcshareddata/xcschemes/ReelSpan.xcscheme`
- Modify: `ReelAtlas/Resources/Localizable.xcstrings`
- Add: `ReelAtlas/Resources/Tips.storekit`
- Remove from active code/resources: old hard-coded poster Supabase project and duplicate TMDB image/cache implementation.

**Interfaces:**
- Xcode app target compiles every merged Swift source once.
- SwiftPM core target includes all `ReelAtlas/Core` files automatically.

- [ ] Merge project references/build phases from dynamic branch into Supabase project.
- [ ] Verify no duplicate source/resource entries.
- [ ] Scan for `qvfdtvfgnlpctcykpfgy`, `reelspan-tmdb.xiaoguiwk.workers.dev`, and Safari detail routing.
- [ ] Run `swift test` and Python tests.

### Task 7: Regression Review and Delivery

**Files:**
- Update: `docs/TODO.md`
- Update: `DELIVERY_NOTES.md`

**Interfaces:**
- Delivery ZIP is a self-contained merged ReelAtlas-iOS project plus Supabase migration.

- [ ] Review map selection coordinate code against both branches and keep the newer safe behavior; do not introduce speculative geometry changes without a reproducible failing case.
- [ ] Verify cold-start fallback, pagination, local-only search mapping, metadata source precedence, native detail routing, and cache clear behavior by tests/source inspection.
- [ ] Run all available verification commands and capture exact results.
- [ ] Create the final ZIP under `/mnt/data`.
