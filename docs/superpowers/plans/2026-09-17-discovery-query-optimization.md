# Discovery Query Optimization Implementation Plan

Goal: preserve released RPC results while removing whole-catalog text scoring and wide pagination.

Architecture: retain the deployed default-browse wrapper; optimize its search delegate with indexed candidate IDs, unchanged ranking/filter predicates, and post-pagination details. Add a five-second anonymous timeout and an empty-error retry action that preserves cached rows.

Approved design: user confirmed candidate-first text and filter optimization, regression testing, merge and build in this conversation.

## Tasks

- [x] Capture old delegate results for Titanic, country, city, year, genre, title sort, place search, next page and unspecified city; demonstrate current anonymous timeout.
- [x] Create migration through `supabase migration new discover_indexed_candidates`. Add stored searchable text and trigram indexes; retain all candidates and original score/order/filter semantics. Move overview/genres loading after pagination.
- [ ] Compare complete JSON rows against captured baselines and test literal wildcard queries; verify real anonymous HTTP timing and pagination.
- [x] Add manual retry only to unavailable empty state; initialize missing story content or refresh the current request without clearing cached rows. Compile application and run Swift, Python, sync and count tests.
- [x] Record production migration and remaining limitations, update release numbering, archive Build 13, verify signing/version/dSYM and authorized upload, commit and push main.

Constraints: bundle com.xiaoguiwk.ReelSpan; public read-only discovery API; no new raw table access; no secrets/artifacts committed; no review submission. Performance goal is common database queries below one second, measured rather than assumed.

2026-09-17 status: full high-frequency search verification remains incomplete; server deployment paused by the user. Generic chunk redesign is an undeployed draft, not an executed plan. User's revised sequence is push main, upload the verified client Build 13 archive, then describe remaining Supabase issues. Client tests: 92 Swift, 68 Python, sync/count integration passed.
