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
- Movie list: small local poster, title, release year, runtime, genre tags, TMDB rating/count, story locations and story times.
- Movie detail: backdrop, larger poster, overview, director, cast, full time/location data, runtime and release metadata.
- Favorites stored only on device.
- Feature-length documentaries remain in the movie dataset.
- No TV series and no books in MVP.

## Purchase model
`PurchaseManager.productID` is currently:

`com.reelatlas.fullaccess`

The Release build checks a StoreKit 2 non-consumable entitlement before allowing access. Debug builds bypass the gate so the project can be tested before App Store Connect is configured. Restore Purchase is included in both the paywall and Settings.

## Local databases
The project deliberately separates replaceable content data from user data.

### `content_seed.sqlite`
Core database imported from the current regional CSV package, containing:
- all fields from `target.csv`, `movies.csv`, `movie_target_matches.csv`, `movie_locations.csv`, `movie_periods.csv`, `places.csv`, and `normalization_issues.csv`,
- unmodified JSON payloads and all movie/place/administrative QIDs,
- target-scoped movie-location rows so `is_target_match` retains its regional meaning,
- unique movie-to-target matches and independent story-period ranges.

### `ContentText_en.sqlite`
English movie title/overview language pack.

### `ContentText_zh-Hans.sqlite`
Simplified-Chinese movie title/overview language pack.

The app also checks `Application Support/ReelAtlas/Languages/ContentText_<language>.sqlite` first. That allows later downloadable language packs without changing the core content schema.

Movie labels now come directly from each CSV `labels_json` value. Resolution uses the selected/system language and then English.

Map labels remain controlled by Apple Maps and the system locale.

### `user.sqlite`
Created at runtime and kept separate from content updates. It stores favorites and local preferences. Replacing the movie database therefore does not overwrite favorites.

## i18n
UI copy uses `ReelAtlas/Resources/Localizable.xcstrings` and follows the iPhone system language. English and Simplified Chinese are included in this MVP. The movie-content language setting is separate from the app UI language and follows the fallback rule above.

## Image strategy
- Small posters are bundled locally for the MVP.
- Settings offers **Download Large Posters** and **Download Backdrops**.
- Downloaded files are stored under Application Support and can be cleared independently.
- The sample seed intentionally contains no production TMDB image URLs; real URLs are supplied by the licensed production ETL.

## CSV import files
- `Data/schema.sql` — schema for the current CSV fields.
- `Data/content_seed.sqlite` — canonical imported database.
- `Scripts/import_csv.py` — repeatable ZIP/directory importer.
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
