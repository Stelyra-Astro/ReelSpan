# Supabase-First Branch Merge Design

## Goal

Merge `codex/supabase-content-sync` and `codex/dynamic-metadata` without discarding either branch's working behavior. Keep Supabase story-content synchronization and offline SQLite as the ReelSpan story-data authority, restore the dynamic metadata/native-detail UI, and make movie metadata resolve through device cache → Supabase → Cloudflare Worker fallback.

## Story data

- `story_movies`, `story_movie_periods`, `story_movie_locations`, `story_places`, `story_targets`, and `story_movie_target_matches` remain the ReelSpan-owned canonical data in Supabase.
- On every first launch/cold launch, the app requests `dataset_meta`. If the story `source_version` differs from the installed SQLite cache, it rebuilds the local story cache from Supabase. If unchanged, it immediately reuses the local SQLite cache.
- If Supabase story sync fails and a local SQLite cache exists, the app continues offline from that cache.
- Initial geolocation/map selection waits until story content is ready so QIDs/coordinates are never surfaced as movie/place display names.

## Movie metadata read path

For a known local `tmdb_id`, the app resolves detail metadata in this order:

1. device persistent movie cache (30-day TTL, shared 150 MiB metadata/image budget);
2. Supabase `public.movies`, selecting only `payload` for the matching `tmdb_id` with the publishable key;
3. `https://tmdb.xiaoguiwk.top/movie/{tmdb_id}?language=en-US` when Supabase has no row or the Supabase lookup fails non-fatally;
4. the Worker requests TMDB and permanently upserts `public.movies` plus `Storage/posters`, then returns the same payload;
5. the app stores the successful payload in its device cache.

No TMDB secret or Supabase service-role secret is embedded in the app. The app may contain the Supabase publishable key already used by story sync.

## Movie search

- Place search keeps current local/MapKit behavior.
- Movie title search uses the Worker search endpoint after debounce because the Supabase `movies` cache is incomplete during backfill.
- Worker movie search results are filtered against local `story_movies` by `tmdb_id`; a movie absent from the ReelSpan story database is not shown.
- Suggestions are ordered places first, movies second, deduplicated, with a hard maximum of 10 combined candidates.
- Choosing a movie opens native `MovieDetailView` directly. IMDb is only an explicit link inside the native detail page.

## Drawer and pagination

- A location/time query returns stable ReelSpan candidate movies from local SQLite.
- Drawer pagination is 15 items per page.
- Visible rows hydrate through the shared metadata store and display TMDB/Supabase title, release year, runtime, genres, rating, vote count, and poster. QID is never a UI fallback title.
- Metadata list requests use one-second dwell, at most two concurrent list loads, cancellation for offscreen rows, and detail-priority scheduling.

## Ranking

Default drawer ordering uses Bayesian weighted TMDB rating rather than release year. The score is:

`(v / (v + m)) * R + (m / (v + m)) * C`

with initial constants `C = 6.5` and `m = 500`.

To avoid downloading full payloads for ranking, Supabase exposes a compact `movie_rankings` view derived from `movies.payload` (`tmdb_id`, `rating`, `vote_count`). The app bulk-fetches rankings only for the location/time candidate TMDB IDs, ranks candidates, then paginates. Candidates not yet present in Supabase receive no score and sort after ranked candidates with stable ID tie-breaking. If the ranking endpoint is unavailable, the app falls back to stable local ordering without blocking the drawer.

## Native detail

`MovieDetailView` is restored from the dynamic-metadata branch. It shows ReelSpan story time/location immediately and progressively hydrates TMDB metadata. It contains an IMDb external link and favorite control. Search, drawer, and favorites all route to this native detail view.

## Cache

- Movie JSON and downloaded images use one persistent cache root under Application Support.
- Metadata TTL: 30 days.
- Combined metadata + image budget: 150 MiB.
- Eviction: expired entries first, then LRU.
- Movie cache is not included in iCloud backup because it is reproducible third-party data.
- Settings can clear only movie metadata/image cache without deleting story SQLite, favorites, or preferences.

## Merge precedence

- Story sync/bootstrap/local SQLite: `codex/supabase-content-sync` wins.
- Dynamic metadata models/cache/service/store, native detail, search debounce, 15-item pagination, Tip code: `codex/dynamic-metadata` wins, adapted to Supabase-first reads.
- Old hard-coded poster project (`qvfdt...`) and direct IMDb routing are removed.
- Worker host is `https://tmdb.xiaoguiwk.top`.

## Verification

- Swift package tests cover Supabase hit, Supabase miss → Worker fallback, cache precedence, search filtering/order/limit, request construction, cache TTL/LRU, and Bayesian ranking.
- Existing story-sync Python tests remain green.
- Search source scans find no old Worker domain, old poster Supabase project, or direct IMDb detail routing.
- Build verification is run as far as the execution environment supports; if Xcode is unavailable, Swift package and static project validation are required and the limitation is reported explicitly.
