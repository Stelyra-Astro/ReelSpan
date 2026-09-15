# Dynamic Movie Metadata, Search, and Tip Design

## Goal

ReelSpan will obtain all TMDB-provided movie metadata at runtime through the project's Cloudflare Worker, cache requested data locally under explicit age and size limits, restore the native movie detail page, keep text input responsive during search, and offer optional StoreKit 2 tips.

## Data ownership

The bundled content database remains authoritative for ReelSpan-owned data:

- stable internal movie ID and Wikidata movie QID;
- `tmdb_id` and IMDb ID mappings;
- story-time ranges, historical periods, story locations, coordinates, sources, normalization paths, and confidence values;
- ReelSpan-owned labels that describe its time/location research rather than the movie's TMDB metadata.

The app bundle must not contain TMDB-provided titles, original titles, summaries, taglines, poster or backdrop paths/files, release dates, runtimes, original languages, production countries, genres, ratings, vote counts, popularity, directors, cast members, character names, or profile images. Existing CSV importer columns, bundled SQLite columns, language databases, JSON fixtures, and bundled poster assets that carry these values will be removed or regenerated without them. Runtime caches are explicitly allowed because they are created only after user-driven loading.

IMDb ID remains in the identity mapping so the detail page can open a precise IMDb title URL. When it is absent, the existing encoded IMDb title-search fallback may use the currently loaded TMDB title.

## TMDB identity completion

Before rebuilding the bundled database, a repeatable script will collect rows whose `tmdb_id` is missing and query Wikidata by their existing movie QIDs for property `P4947` (TMDB movie ID). It will validate that each value is a positive integer and update only unambiguous results. It will never match by title automatically.

The script will emit a machine-readable report containing the starting missing count, mappings added, invalid or conflicting claims, request failures, and unresolved QIDs. Network responses will be saved as build artifacts, not app resources. The final report will state both the original count (currently 3,162 of 49,995 movies) and the verified remaining count.

## Runtime models

The current `MovieViewData` interface remains the presentation model used by existing views. The bundled repository constructs it with identity and ReelSpan story fields plus empty metadata placeholders; the shared metadata store returns an enriched copy after a Worker response. This preserves existing feature interfaces while ensuring the placeholder fields are never populated from bundled TMDB data.

New network-only models are limited to:

- `MovieMetadata`: the Worker movie-detail response, including multiple directors and cast members.
- `MovieSearchPage` and `MovieSearchItem`: the Worker search response and pagination fields.

No view or view model may construct a TMDB or Worker URL. Image URLs are produced by a single metadata/image URL builder and return `nil` for absent or invalid paths.

## Worker API boundary

`MovieMetadataService` is the only owner of the Worker base URL:

`https://reelspan-tmdb.xiaoguiwk.workers.dev`

Supported operations are:

- `GET /movie/{tmdb_id}?language=en-US` for a known TMDB ID;
- `GET /search/movie?query={query}&language=en-US&page={page}` only for active user movie search or an explicit missing-ID lookup workflow.

All requests use `en-US` because the current persistent Worker cache supports only that language. Known TMDB IDs always use the detail endpoint and are never rematched by title. The iOS project must contain no TMDB API key, TMDB read access token, Supabase secret key, `api.themoviedb.org` request, direct Supabase database request, or direct-IP TLS transport.

The app treats the Worker's `Cloudflare Cache → Supabase → TMDB` implementation as an opaque server concern. It neither reproduces that pipeline nor attempts to access its database. For movie-detail posters, `posterUrl` from the Worker is the primary image URL. Only when `posterUrl` is absent or invalid may the central image URL builder derive a fallback from `posterPath`. Search results currently lack `posterUrl`, so their temporary thumbnails may use a centrally constructed `posterPath` fallback until detail metadata loads. Other image paths use the same centralized validation rule. A fallback path must begin with `/`; `nil` and malformed paths produce no URL.

Requests use async/await and an injected `URLSession`-compatible transport for testing. The service applies a finite request timeout and maps offline/cancellation, timeout, 404, 429, 5xx, decoding, and other response failures into explicit error categories. Cancellation is never surfaced as a user-visible error.

## Runtime cache

Metadata JSON and downloaded images are stored below Application Support only after a request. This device cache is independent from, and has no knowledge of, the Worker's Cloudflare/Supabase caching. Metadata cache keys include TMDB ID, fixed language `en-US`, schema version, and response kind. Image keys include the resolved source URL and requested presentation size so list and detail variants cannot collide.

Default policy:

- maximum age: 30 days from successful write;
- maximum total size: 150 MiB across metadata and TMDB images;
- eviction: expired entries first, then least-recently-used entries until under the limit;
- writes: atomic, and only after a complete successful response;
- corrupt entries: delete and treat as a cache miss;
- cached results: display immediately, then refetch only when expired;
- failed refresh: retain no partial response; an already displayed stale value may remain for the current screen while the error is represented non-destructively.

Cache cleanup runs at service initialization and after successful writes. Clearing the cache removes only runtime TMDB metadata/images and resets in-memory metadata state. The existing iCloud backup must stop copying TMDB runtime cache because remotely reproducible third-party metadata is not user-authored data.

## Loading and priority

`MovieMetadataStore` is a main-actor observable facade backed by the service and a request scheduler. It deduplicates requests by TMDB ID and fixed language `en-US` and exposes per-item states: idle, loading, loaded, unavailable, and failed.

- A visible drawer or favorites row waits for a continuous one-second dwell before requesting metadata.
- At most two list requests run concurrently at utility priority.
- Rows leaving the visible region cancel their dwell and any request no longer needed by another visible consumer.
- Opening a detail page immediately requests that movie at user-initiated priority, cancels queued list work, and suspends new list requests while detail is active.
- Dismissing the detail page cancels its unfinished metadata and image work, then resumes requests only for rows that are still visible.
- Search-query changes cancel debounce, Worker search, and obsolete result-detail work.
- Every response carries or is checked against a request identity so an older completion cannot overwrite newer UI state.

Cancellation must propagate through URLSession and image downloads. Views use SwiftUI task cancellation hooks (`task(id:)`, `onDisappear`, or equivalent ownership wrappers); detached, unowned request tasks are prohibited.

## Search responsiveness

The current movie search performs a full local SQLite scan through a serial actor and can make later queries wait behind obsolete work. It will be removed as the movie-title source. Place search remains local/MapKit-based, while active movie search uses the Worker endpoint after a 250 ms debounce and a minimum normalized length of two characters.

Text editing must never await candidate generation. Each keystroke updates the text binding synchronously, cancels the preceding search task, and schedules new work. Only the latest normalized query and page may publish results. Loading indicators cannot replace, disable, resign, or rebuild the text field. The suggestion overlay has a stable container identity so arrival of the first movie result does not disturb first-responder state or cursor position.

Regression coverage will include rapid typing where an early query returns after a later query, cancellation before debounce, cancellation during transport, first-result insertion while editing, and continued input while the candidate list is loading. UI instrumentation will record main-thread work around text changes to confirm the actual blocker before the production fix is selected.

Worker search results are presented from `MovieSearchItem`. If a result's TMDB ID maps to a local movie record, its ReelSpan story data is attached to the runtime `MovieViewData`. Otherwise the result may open a metadata-only detail page with story-time/location placeholders; search does not silently create bundled database records.

## Views

Drawer rows, favorites rows, user movie-search results, and `MovieDetailView` continue consuming `MovieViewData`, enriched through the shared store.

Rows initially show a fixed-size skeleton/placeholder and ReelSpan story-time/location data. On metadata arrival they update title, year, runtime, genres, rating, vote count, and poster without changing scroll identity. Detail-derived rows prefer the Worker's `posterUrl`; search-only results may use the centralized `posterPath` fallback. Tapping any movie opens the native `MovieDetailView`, never IMDb directly.

The restored detail page immediately shows ReelSpan story information and placeholders for metadata. It progressively adds the TMDB title, original title when different, overview fallback text, tagline, the Worker-supplied `posterUrl` image, backdrop, release/runtime/language/status, genres, rating, multiple directors, and cast/profile images. `posterPath` is used only when `posterUrl` is empty or invalid. Empty overview, director, or cast values use existing localized unavailable states rather than hiding ReelSpan story content.

The detail page includes an explicit IMDb link. The favorite control remains in the hero/summary area. Directly below it, a small Tip button presents the tip sheet.

## Tip purchases

StoreKit 2 uses three consumable products: `com.xiaoguiwk.ReelSpan.tip.small`, `com.xiaoguiwk.ReelSpan.tip.medium`, and `com.xiaoguiwk.ReelSpan.tip.large`. App Store Connect defines their localized prices. The sheet loads the live `Product` values and displays each product's `displayPrice`; verified transactions are finished without creating an entitlement.

Purchasing calls `product.purchase()`. Verified transactions are finished; pending, cancellation, unverified transactions, parental/payment restrictions, unavailable products, and StoreKit errors receive distinct non-destructive states. A tip grants no entitlement and does not alter app access. The Tip control is hidden or disabled with an explanatory state when purchases are unavailable. The App Store Connect product configuration and StoreKit test configuration are delivery prerequisites outside source code.

## Failure behavior

TMDB/Worker failure never blocks map selection, time filtering, story locations, favorites, or access to cached data. A missing TMDB ID never triggers an automatic title search during list/detail loading. A 404 becomes an unavailable state for that identity; 429 and 5xx may expose a retry action but do not loop automatically. Placeholders are used for missing images and absent fields. User-facing errors remain concise and localized; diagnostic categories are testable without exposing secrets or full request URLs.

## Migration and cleanup

The migration will update the importer, schema, generated content database, runtime repository queries, domain models, language-pack handling, and bundled resources. It will inspect every source and resource for obsolete metadata dependencies. Legacy runtime cache formats are versioned out and removed safely during initialization.

Completion scans must find no TMDB/Supabase secret patterns, old Worker domain, `api.themoviedb.org`, direct Supabase database endpoint, direct API IP list, Keychain API-key store, metadata-setting UI, old TMDB response coding keys, bundled TMDB poster directory, or view-level API URL construction. `image.tmdb.org` remains intentionally present only in the central fallback image URL builder.

## Verification

Testing follows red-green-refactor cycles and covers:

- decoding the observed Worker detail and search JSON shapes, including `null` paths and empty arrays;
- exact Worker URL construction, query encoding, fixed `en-US` requests, `posterUrl` precedence, `posterPath` fallback, and absence of authentication material;
- HTTP/error mapping, timeouts, request cancellation, deduplication, concurrency limit, and detail priority;
- cache hit/expiry/corruption/LRU eviction/atomic writes and the 30-day/150-MiB policy;
- rapid search typing, latest-response wins, and preserved input focus/cursor behavior;
- local story data remaining usable with missing metadata, missing TMDB ID, and every required failure class;
- multi-director and cast presentation, IMDb link behavior, and placeholder image behavior;
- StoreKit product loading, verified completion, pending, cancellation, and unverified results for all three Tip products;
- importer/schema tests proving prohibited TMDB metadata is absent from the generated app database;
- a database audit reporting total movies, TMDB IDs added from Wikidata, and unresolved IDs;
- full Swift package tests and an unsigned iOS Simulator build.

Final reporting lists modified files, new services/models, migrated pages, any remaining local metadata dependencies, the verified missing-TMDB-ID count, and fresh test/build results.
