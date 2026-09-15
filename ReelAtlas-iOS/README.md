# ReelSpan iOS MVP

Native SwiftUI/MapKit movie-discovery app implementing the agreed MVP: select a place and story year, then discover movies whose narrative locations and story-time ranges match. The app is account-free, uses a local movie database, stores favorites locally, and is designed for a one-time App Store purchase.

## Open in Xcode
1. Open `ReelSpan.xcodeproj`.
2. Select the `ReelSpan` scheme and an iPhone/simulator.
3. In **Signing & Capabilities**, choose your development team.
4. Replace `com.example.ReelSpan` with the final bundle identifier.
5. Build and run on iOS 17 or later.

The generation environment does not contain Xcode/MapKit, so the final native target must be compiled once in Xcode. Pure Swift core rules are verified here with `swift test`.

## MVP behavior
- Full-screen Apple Maps / MapKit interface.
- Search for a place or tap directly on the map.
- Story-year slider plus direct year picker, including BCE years.
- Multiple independent story-time ranges per movie.
- Multiple direct narrative locations per movie.
- Exact location first; if there are no results, fall back through administrative parents until country.
- Movie list: dynamically cached poster, title, release year, runtime, genre tags, TMDB rating/count, story locations and story times.
- Movie detail: backdrop, larger poster, overview, director, cast, full time/location data, runtime and release metadata.
- Favorites stored only on device.
- Feature-length documentaries remain in the movie dataset.
- No TV series and no books in MVP.

## Purchase model
`PurchaseManager.productID` is currently:

`com.reelatlas.fullaccess`

The Release build checks a StoreKit 2 non-consumable entitlement before allowing access. Debug builds bypass the gate so the project can be tested before App Store Connect is configured. Restore Purchase is included in both the paywall and Settings.

## Supabase content and local cache
The project separates server-owned story content from runtime user data.

### Story content
`Data/content_seed.sqlite` is the canonical ETL output used by
`Scripts/upload_story_content.py`. The upload populates the `story_*` tables in
the ReelSpan Supabase project. The app bundle contains no content database.

At launch, the app reads `dataset_meta`, downloads the current `story_*` rows
when the version changes, and atomically rebuilds
`Application Support/ReelAtlas/content.sqlite` as an offline cache containing:
- all fields from `target.csv`, `movies.csv`, `movie_target_matches.csv`, `movie_locations.csv`, `movie_periods.csv`, `places.csv`, and `normalization_issues.csv`,
- unmodified JSON payloads and all movie/place/administrative QIDs,
- target-scoped movie-location rows so `is_target_match` retains its regional meaning,
- unique movie-to-target matches and independent story-period ranges.

TMDB-owned title, poster, overview, cast, and director data are not stored in
the `story_*` tables. They remain the responsibility of the TMDB metadata path.

Map labels remain controlled by Apple Maps and the system locale.

### `user.sqlite`
Created at runtime and kept separate from content updates. It stores favorites and local preferences. Replacing the movie database therefore does not overwrite favorites.

## i18n
UI copy uses `ReelAtlas/Resources/Localizable.xcstrings` and follows the iPhone system language. English and Simplified Chinese are included in this MVP. The movie-content language setting is separate from the app UI language and follows the fallback rule above.

## Movie metadata and image strategy
- Movie rows use dynamic TMDB metadata rather than titles embedded in the story SQLite cache.
- Detail resolution is device cache → Supabase `public.movies.payload` → `https://tmdb.xiaoguiwk.top` fallback.
- The Worker is the only TMDB credential holder. On a cache miss it fetches TMDB data, stores the movie in Supabase and copies the w185 poster to the public `posters` bucket.
- Device movie metadata and posters share a 30-day / 150 MiB persistent cache. Settings can clear this cache without removing story content, favorites, or preferences.
- The drawer is paged in groups of 15. Search suggestions show places first and database-backed movies second, with at most 10 suggestions total.

## CSV import files
- `Data/schema.sql` — schema for the current CSV fields.
- `Data/content_seed.sqlite` — canonical local ETL output; not an app resource.
- `Scripts/import_csv.py` — repeatable ZIP/directory importer.
- `Scripts/upload_story_content.py` — idempotent Supabase uploader.
- `docs/DATA_PIPELINE.md` — merge, validation, and runtime-query contract.

The legacy language-pack and sample JSON fixtures are not inputs to the current import.

## Xcode verification
After opening the project, run:

```bash
xcodebuild -project ReelSpan.xcodeproj \
  -scheme ReelSpan \
  -sdk iphonesimulator \
  -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO
```

Then test on an iPhone for MapKit place search/tap selection, StoreKit sandbox purchase/restore, image downloads, localization, and local favorites.
