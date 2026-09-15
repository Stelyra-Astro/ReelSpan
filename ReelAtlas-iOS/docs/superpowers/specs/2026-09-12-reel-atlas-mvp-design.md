# ReelSpan MVP Design

## Product
A native iOS movie-discovery app using Apple Maps as the spatial interface. Users choose a place and story year to discover feature films and feature-length documentaries whose narrative locations match the place (with administrative fallback) and whose one or more story time ranges contain the selected year.

## Platform and commercial model
- SwiftUI + MapKit, iOS 17+.
- No account.
- Free to use. Optional consumable tips are processed by Apple through StoreKit 2 and do not unlock features or create entitlements.
- Story data and user settings are cached locally on device; movie metadata and images are delivered through ReelSpan-operated infrastructure. MapKit remains an Apple online service.

## Data
- Wikidata-aligned core: QID, `P840` narrative locations, `P2408` set-in-period raw provenance, normalized independent story time ranges, location ancestors, TMDB ID.
- TMDB enrichment: title/translations, small poster, optional large poster/backdrop URLs, overview, runtime, release date, genres, director, cast, vote average/count.
- SQLite content database is replaceable independently of user data.
- User database stores favorites and local preferences.
- Small posters ship locally in the MVP. Large posters and backdrops are optional user-triggered downloads to Application Support.

## Time normalization
- A movie may have multiple independent time ranges; do not merge gaps.
- Query matches when any range contains selected year.
- Wikidata contemporary/contemporary-history values normalize to the movie release decade, e.g. release 1994 => 1990–1999.
- Preserve source period QID, normalization type and confidence.

## Location normalization
- A movie may have multiple direct narrative locations.
- Preserve direct locations; precompute ancestor hierarchy for matching.
- Search exact selected place first. If no matching movies for selected year, fall back one administrative parent at a time until country.
- UI explicitly discloses fallback.

## Localization
- Default to device preferred language.
- Per movie text fallback: preferred language => English => original language.
- Map labels are handled by Apple Maps/system locale.
- Language packs are local resources; architecture permits later downloadable packs.

## Ranking
Use Bayesian weighted rating based only on TMDB vote average and vote count. Precompute `ranking_score` during ETL when possible; runtime can recompute as fallback.

## Home UI
- Full-screen Apple Map.
- Time slider above map search bar; tapping year opens direct-year picker.
- Search bar + settings button.
- Selected location pin.
- Bottom sheet list. Card: local small poster, title, release year, runtime, genre pills, TMDB rating/count, direct narrative location(s), story time range(s), favorite button.

## Movie Detail
- Backdrop hero and larger poster when locally available/downloaded; small poster fallback.
- Localized title, overview, release year/date, runtime, genres, rating/count, all story ranges, all direct narrative locations, director and cast.
- Favorite toggle.

## Settings
- Language / system default and fallback explanation.
- Appearance/map appearance placeholders.
- Genre availability.
- Local Data section reserved for future data controls.
- Image downloads: large posters; backdrops; cache size/clear.
- Purchase status and restore.
- Privacy Policy, Terms of Use, Data Sources, TMDB Attribution, Open Source Licenses, Help & Feedback, About/version/database version.

## MVP boundaries
- Movies only; no TV series.
- Feature-length documentaries count as movies.
- No books.
- No server backend or account sync.
