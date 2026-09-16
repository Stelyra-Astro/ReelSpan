# Reel Atlas Full Catalog and Discovery Implementation Plan

**Goal:** Replace the 551-film target-match bootstrap with resumable 250-film batches and a searchable 49,995-film server catalog; add categorized historical When and list/map UI.

**Architecture:** Supabase SQL RPC searches published story films, movie metadata, place/time associations, and a new time-concept catalog; SwiftUI lists paged RPC results independently of local cache. An actor persists per-batch SQLite data, sync cursor and target version; AppModel enters after initial batch and updates views on further commits.

**Tech Stack:** SwiftUI iOS 17, SQLite3, Supabase PostgREST/Postgres SQL, Python source-contract tests.

**Spec:** Confirmed requirements in the current project conversation.

## Tasks
- [x] Validate pre-change snapshot of 10 public tables; no Storage mutation.
- [x] Correct unambiguous century/decade spans; create time concepts and evidenced concept tags; test counts.
- [x] Deploy SQL unified discovery RPC and exercise Manchukuo relevance ordering.
- [x] Test and implement resumable 250-film SQLite batches, with progress and fingerprint lifecycle.
- [x] Test and integrate full-catalog RPC and When categories, modern Where, list/map native SwiftUI UI.
- [x] Run Swift parser and available tests; package source ZIP and specify unverified iOS-device behavior.
