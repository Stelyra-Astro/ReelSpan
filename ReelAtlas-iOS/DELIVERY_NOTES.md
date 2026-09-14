# Delivery Notes

## Implemented
- Native SwiftUI iOS 17+ project.
- Apple Maps / MapKit map, place search and direct map tapping.
- Story-year slider and direct year entry, including BCE support.
- Exact location matching plus administrative-parent fallback.
- Multiple narrative locations and multiple independent story-time ranges.
- Local movie list and movie detail UI.
- Local favorites in separate `user.sqlite`.
- Local small posters; optional large-poster and backdrop downloads.
- Wikidata-aligned P840/P2408 provenance schema.
- Bayesian TMDB rating/vote ranking field.
- UI i18n with English + Simplified Chinese String Catalog.
- Movie-language fallback: preferred/system → English → original language.
- Core content DB separated from per-language movie text DBs.
- StoreKit 2 one-time purchase/restore plumbing; Debug build bypasses purchase gate for development.
- Privacy, Terms, Data Sources, TMDB Attribution, Licenses, Help and About screens.

## Data included
The bundled data is intentionally illustrative and contains eight development movie records. The production import contract is in `docs/DATA_PIPELINE.md`.

## Verified in generation environment
- `plutil -lint ReelSpan.xcodeproj/project.pbxproj`: pass.
- SQLite `PRAGMA integrity_check`: pass for core/en/zh-Hans DBs.
- Xcode source/resource file inventory: pass.
- All Swift app source files parse successfully.
- `swift test`: 7 tests, 0 failures.

## Must be verified in Xcode
This environment has no Xcode/iOS SDK. Run:

```bash
xcodebuild -project ReelSpan.xcodeproj -scheme ReelSpan -sdk iphonesimulator -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

Then test MapKit search/tap, StoreKit sandbox flow and image downloads on an iPhone.
