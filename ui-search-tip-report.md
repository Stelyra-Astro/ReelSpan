# UI / search / Tip integration

Implemented on `codex/ui-and-tip`, based on `5e3467e`. No database, schema, or Wikidata data changed. No Superpowers skills or additional agents used. No UI automation or Simulator interaction performed.

## Changes

- `AppModel.swift`: owns the shared metadata store and lifetime Tip manager; local indexed-place and search identity lookup now execute in a serial background actor. Removed all `MovieSearchWorker` usage. Negative remote-only movie identities cannot be persisted as local favorites.
- `HomeView.swift`: Drawer, Favorites and remote search open the native `MovieDetailView`. Search uses Worker through the shared service, 250 ms debounce, minimum 2 characters, cancellation plus generation guard. Clears old results immediately. SQLite no longer runs during search-body calculation. UITextField no longer reloads its input views; marked text, selection and focus are retained during candidate updates. Search failure is visible. Search movie candidates show cached thumbnails.
- `MovieRowView.swift`: dynamically enriches titles, genres and runtime, begins the store's 1-second visibility dwell on appearance and ends its consumer on disappearance.
- `MovieDetailView.swift`: immediate high-priority detail lifecycle, loading/failure placeholders, preserved story information, multiple directors, cast and null-profile placeholders, explicit IMDb external link, Tip beneath favorite. Only metadata-driven artwork is used.
- `LocalPosterView.swift`: cancellable image `.task(id:)` using the shared service/cache; primary `posterUrl`, centrally defined w185 list / w342 detail fallback; no URL concatenation in Views or legacy downloads.
- `AppModels.swift`: `enriching(with: MovieMetadata)` and search result construction preserve internal/QID/TMDB identity and story ranges/locations while replacing metadata. Multiple directors are joined for the existing UI model.
- `ContentRepository.swift`: added only `movie(tmdbID:preferredLanguage:)`, a small ID lookup required for connecting remote search results to local story records. Data branch should retain this method.
- `SearchAndTip.swift`: observable latest-query coordinator and testable Tip quantity/state rules.
- `PurchaseManager.swift`: separate StoreKit 2 consumable manager, product `com.reelatlas.tip`, quantity 1...10, verified finish, cancellation/pending/unverified/failure handling and a long-lived transaction-updates listener. Existing full-access manager is preserved.
- `Tips.storekit`: local 0.99 test base product. The app always displays real `Product.priceFormatStyle` totals, with 1/3/5 shortcuts and custom 1...10. This file is a project reference, not a Release bundle resource or default scheme override.
- `ImageDownloadManager.swift`: old unused enrichment method returns its input, eliminating the stale model-type compiler dependency. Parent integration still needs to remove the legacy manager/key/direct-IP code and corresponding AppModel cache/iCloud hooks.
- Settings already contained no TMDB key UI at this baseline; no settings view change was necessary.

## Verification

- Added the focused tests first and observed expected missing-implementation compile failures.
- `swift test --filter 'SearchAndTipTests|testMovieMetadata'`: 11 passed, 0 failed. Includes actual in-flight cancellation and repeated query generation guard, quantity/state validation and poster precedence/fallback checks, plus existing cache checks.
- Actual app-model non-UI checks passed: identity and story preservation, dynamic fields, multiple directors, null actor avatar, primary poster URL, IMDb external URL, local/remote search identity.
- iOS Simulator generic build with signing disabled passed (both supported simulator architectures). Initial failure was the legacy enrichment signature; subsequent sandbox macro-service denial required the authorized out-of-sandbox compiler run. Only compilation was performed; no simulator boot, UI launch or gestures.
- `git diff --check` passed.

Re-run the app-model check from `ReelAtlas-iOS`:

```sh
xcrun swiftc ReelAtlas/Core/Domain.swift ReelAtlas/Core/HistoricalYearFormatter.swift ReelAtlas/Core/LanguageResolver.swift ReelAtlas/Core/MovieMetadataModels.swift ReelAtlas/App/L10n.swift ReelAtlas/Data/AppModels.swift Tests/ModelChecks/MovieViewDataChecks.swift -o /private/tmp/reelspan-model-checks
/private/tmp/reelspan-model-checks
```

## Integration notes and remaining external setup

- Likely conflict files: `AppModel.swift`, `AppModels.swift`, `ContentRepository.swift`, `CoreRulesTests.swift`, `project.pbxproj`, and legacy `ImageDownloadManager.swift` slated for removal. Preserve new Worker search, actor and metadataStore usage when replacing old cache/iCloud hooks.
- Search-only films absent from ReelSpan's own database show dynamic details and unknown story fields; their favorite button is disabled. This avoids inventing permanent story identities. Existing indexed-film favorites continue working.
- Existing store handles dwell/priority/cancellation; this branch did not change its scheduling algorithm. Parent should retain service/cache/scheduler tests and audit all removed direct-TMDB code after merging.
- Create the real consumable `com.reelatlas.tip` in App Store Connect for production/Sandbox purchases. Product availability depends on that configuration. For local manual testing: Xcode Edit Scheme → Run → Options → StoreKit Configuration → choose `ReelAtlas/Resources/Tips.storekit`. Do not select this file for production purchase verification.
- Parent remains responsible for final integrated full tests, iPhone 12 mini installation and Release Archive.

## User manual checks (not executed)

1. Type a matching movie name rapidly, then keep typing/delete/retype; candidate loading must not freeze input or move the cursor. Repeat with Chinese marked text, paste and keyboard dismissal.
2. Tap Drawer, Favorites and search candidates; all open native details. IMDb opens only through its explicit link. Story time/location remain visible offline or with missing metadata.
3. Scroll quickly past rows, pause on a row for a second, open/close detail during loading and navigate away; visible/detail requests should win and departed consumers cancel. Repeat offline and on slow networking.
4. Check primary Supabase posters, w185 search/list fallback, w342 detail fallback, absent posters/actors and multiple directors.
5. Tip: check localized currency totals for 1/3/5, custom boundaries 1 and 10, success, user cancellation, Ask to Buy pending and failed/unverified states. Tips must not change full-access entitlement.
