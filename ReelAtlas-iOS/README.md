# ReelSpan iOS MVP

Native SwiftUI/MapKit movie-discovery app implementing the agreed MVP: select a place and story year, then discover movies whose narrative locations and story-time ranges match. The app is account-free, downloads the current story dataset from Supabase into an offline SQLite cache, stores favorites locally, and is designed for a one-time App Store purchase.

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
- Movie list: dynamically loaded title, poster, release year, runtime, genre tags, TMDB rating/count, plus bundled ReelSpan story locations and story times.
- Movie detail: backdrop, larger poster, overview, director, cast, full time/location data, runtime and release metadata.
- Favorites stored only on device.
- Feature-length documentaries remain in the movie dataset.
- No TV series and no books in MVP.

## Purchase model
`PurchaseManager.productID` is currently:

`com.reelatlas.fullaccess`

The Release build checks a StoreKit 2 non-consumable entitlement before allowing access. Debug builds bypass the gate so the project can be tested before App Store Connect is configured. Restore Purchase is included in both the paywall and Settings.

## Runtime data and local databases
The project deliberately separates replaceable content data from user data.

### Story dataset
`Data/content_seed.sqlite` is the canonical ETL/upload artifact and is not bundled in the app. On first launch, the app downloads the compact story dataset from Supabase and creates `Application Support/ReelAtlas/content.sqlite`. Later launches reuse that cache until Supabase's dataset version changes.

The story cache contains:
- only `id`, `movie_qid`, `imdb_id`, and `tmdb_movie_id` in `movies`,
- ReelSpan place, administrative, story-location, story-period, source, and confidence data,
- target-scoped movie-location rows so `is_target_match` retains its regional meaning,
- unique movie-to-target matches and independent story-period ranges.

Movie titles, overviews, artwork, release/runtime/rating fields, genres, directors, and cast are requested from the configured metadata Worker and cached locally only after use.

Map labels remain controlled by Apple Maps and the system locale.

### `user.sqlite`
Created at runtime and kept separate from content updates. It stores favorites and local preferences. Replacing the movie database therefore does not overwrite favorites.

## i18n
UI copy uses `ReelAtlas/Resources/Localizable.xcstrings` and follows the iPhone system language. English and Simplified Chinese are included in this MVP. The movie-content language setting is separate from the app UI language and follows the fallback rule above.

## Image strategy
- No movie artwork is bundled.
- Artwork returned by the metadata Worker is cached under Application Support and can be cleared independently.

## CSV import files
- `Data/schema.sql` — runtime schema; verbose upstream movie metadata is validated but not persisted.
- `Data/content_seed.sqlite` — canonical imported database.
- `Scripts/import_csv.py` — repeatable ZIP/directory importer.
- `docs/DATA_PIPELINE.md` — merge, validation, and runtime-query contract.

The legacy language-pack and sample JSON fixtures are not inputs to the current import.

## Xcode verification
After opening the project, run:

```bash
xcodebuild -project ReelSpan.xcodeproj \
  -scheme ReelSpan \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  archive
```

Test the resulting archive on an iPhone for MapKit place search/tap selection, first-launch story sync, StoreKit sandbox purchase/restore, metadata and artwork caching, localization, and local favorites.
