# Dynamic Movie Metadata, Search, and Tip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move all TMDB-provided movie metadata to runtime Worker requests, preserve ReelSpan story data, restore the native detail flow, eliminate search-input blocking, and add StoreKit tips.

**Architecture:** A slim bundled database supplies movie identity and ReelSpan story data while the existing `MovieViewData` remains the UI-facing runtime model. Core `MovieMetadataService`, cache, store, and search-session types own every Worker request and enrich that model without changing existing page interfaces. SwiftUI views observe stable per-movie states, while a separate StoreKit 2 path handles three optional consumable tips.

**Tech Stack:** Swift 6, SwiftUI, Foundation async/await, URLSession, Codable, SQLite, StoreKit 2, XCTest, Python 3 `unittest`, Wikidata Action API.

**Spec:** `docs/superpowers/specs/2026-09-14-dynamic-movie-metadata-search-tip-design.md`

## Global Constraints

- iOS deployment target remains 17.0.
- All metadata and movie-search requests use `https://reelspan-tmdb.xiaoguiwk.workers.dev` with `language=en-US`.
- No TMDB or Supabase secret may exist in the app, and the app never requests `api.themoviedb.org` or the Supabase database.
- Detail posters prefer Worker `posterUrl`; `posterPath` is only the centralized fallback and remains permitted for search-result thumbnails.
- Device cache maximum age is 30 days and aggregate maximum size is 150 MiB.
- Bundled data retains identity and ReelSpan story/time/location/source/confidence data, but no TMDB-provided metadata or poster files.
- A known `tmdb_id` is never rematched by title.
- Tip uses three consumable products: `com.xiaoguiwk.ReelSpan.tip.small`, `com.xiaoguiwk.ReelSpan.tip.medium`, and `com.xiaoguiwk.ReelSpan.tip.large`. The UI displays each product's localized `displayPrice`.

---

### Task 1: Lock the Worker contract in core models

**Files:**
- Create: `ReelAtlas/Core/MovieMetadataModels.swift`
- Create: `ReelAtlas/Core/MovieMetadataRequest.swift`
- Create: `Tests/ReelAtlasCoreTests/TestFixtures.swift`
- Modify: `Tests/ReelAtlasCoreTests/CoreRulesTests.swift`
- Modify: `ReelSpan.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `MovieMetadata`, `MovieSearchPage`, `MovieSearchItem`, `MovieMetadataImageURLs`, and `MovieMetadataRequest`.
- Produces: `MovieMetadataRequest.detail(tmdbID:)` and `.search(query:page:)` with fixed Worker host and `en-US`.

- [ ] **Step 1: Add failing decoding and URL tests**

```swift
func testWorkerDetailDecodesPosterURLDirectorsAndCast() throws {
    let data = #"{"id":550,"title":"Fight Club","originalTitle":"Fight Club","overview":"Overview","tagline":"Tagline","posterPath":"/poster.jpg","posterUrl":"https://cdn.example/posters/550.jpg","backdropPath":null,"releaseDate":"1999-10-15","runtime":139,"originalLanguage":"en","status":"Released","genres":[{"id":18,"name":"Drama"}],"rating":8.4,"voteCount":10,"popularity":3.0,"directors":[{"id":1,"name":"Director","originalName":"Director","profilePath":null}],"cast":[{"id":2,"name":"Actor","originalName":"Actor","character":"Lead","profilePath":null,"order":0}]}"#.data(using: .utf8)!
    let value = try JSONDecoder().decode(MovieMetadata.self, from: data)
    XCTAssertEqual(value.posterURL?.absoluteString, "https://cdn.example/posters/550.jpg")
    XCTAssertEqual(value.directors.map(\.name), ["Director"])
    XCTAssertEqual(value.cast.map(\.character), ["Lead"])
}

func testDetailRequestUsesOnlyWorkerAndFixedEnglish() throws {
    let request = try MovieMetadataRequest.detail(tmdbID: 550).urlRequest
    XCTAssertEqual(request.url?.absoluteString, "https://reelspan-tmdb.xiaoguiwk.workers.dev/movie/550?language=en-US")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
}

func testPosterURLPrefersWorkerThenFallsBackToPath() {
    XCTAssertEqual(MovieMetadataImageURLs.poster(primary: "https://cdn.example/550.jpg", path: "/p.jpg")?.absoluteString, "https://cdn.example/550.jpg")
    XCTAssertEqual(MovieMetadataImageURLs.poster(primary: nil, path: "/p.jpg")?.absoluteString, "https://image.tmdb.org/t/p/w342/p.jpg")
    XCTAssertNil(MovieMetadataImageURLs.poster(primary: nil, path: nil))
}
```

- [ ] **Step 2: Run the focused tests and confirm they fail because the new types do not exist**

Run: `swift test --package-path ReelAtlas-iOS --filter 'WorkerDetail|DetailRequest|PosterURL'`

Expected: compilation failure naming `MovieMetadata`, `MovieMetadataRequest`, and `MovieMetadataImageURLs`.

- [ ] **Step 3: Implement the observed camelCase Worker response types and centralized builders**

```swift
struct MovieMetadata: Codable, Equatable, Sendable {
    let id: Int
    let title: String
    let originalTitle: String
    let overview: String
    let tagline: String
    let posterPath: String?
    let posterUrl: String?
    let backdropPath: String?
    let releaseDate: String?
    let runtime: Int?
    let originalLanguage: String
    let status: String
    let genres: [NamedMovieValue]
    let rating: Double
    let voteCount: Int
    let popularity: Double
    let directors: [MoviePerson]
    let cast: [MovieCast]

    var posterURL: URL? {
        MovieMetadataImageURLs.poster(primary: posterUrl, path: posterPath)
    }
}

enum MovieMetadataRequest {
    static let baseURL = URL(string: "https://reelspan-tmdb.xiaoguiwk.workers.dev")!
    case detail(tmdbID: Int)
    case search(query: String, page: Int)
    var urlRequest: URLRequest { get throws }
}
```

The builder rejects nonpositive IDs, blank queries, pages below one, non-HTTPS `posterUrl`, and fallback paths that do not begin with `/`. Search poster fallback uses `w185`; detail poster fallback uses `w342`; profile fallback uses `w185`.

Add explicit test-only constructors in `TestFixtures.swift`; later tasks reuse these exact helpers:

```swift
extension MoviePerson {
    static func fixture(id: Int = 1, name: String = "Director") -> Self {
        .init(id: id, name: name, originalName: name, profilePath: nil)
    }
}

extension MovieMetadata {
    static func fixture(id: Int = 550, directors: [MoviePerson] = [.fixture()]) -> Self {
        .init(
            id: id, title: "Fight Club", originalTitle: "Fight Club",
            overview: "Overview", tagline: "Tagline", posterPath: "/poster.jpg",
            posterUrl: "https://cdn.example/posters/550.jpg", backdropPath: nil,
            releaseDate: "1999-10-15", runtime: 139, originalLanguage: "en",
            status: "Released", genres: [.init(id: 18, name: "Drama")],
            rating: 8.4, voteCount: 10, popularity: 3,
            directors: directors, cast: []
        )
    }
}
```

- [ ] **Step 4: Run the model tests and the complete core suite**

Run: `swift test --package-path ReelAtlas-iOS`

Expected: all tests pass with no direct API authentication fields.

- [ ] **Step 5: Commit the contract**

```bash
git add ReelAtlas-iOS/ReelAtlas/Core/MovieMetadataModels.swift ReelAtlas-iOS/ReelAtlas/Core/MovieMetadataRequest.swift ReelAtlas-iOS/Tests/ReelAtlasCoreTests/CoreRulesTests.swift ReelAtlas-iOS/Tests/ReelAtlasCoreTests/TestFixtures.swift ReelAtlas-iOS/ReelSpan.xcodeproj/project.pbxproj
git commit -m "feat: model ReelSpan metadata worker contract"
```

### Task 2: Implement device metadata and image caching

**Files:**
- Create: `ReelAtlas/Core/MovieMetadataCache.swift`
- Create: `ReelAtlas/Core/MovieCachePolicy.swift`
- Modify: `Tests/ReelAtlasCoreTests/CoreRulesTests.swift`
- Modify: `ReelSpan.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `MovieMetadata` from Task 1.
- Produces: `MovieMetadataCache.readMetadata(tmdbID:)`, `.writeMetadata(_:tmdbID:)`, `.cachedImage(for:)`, `.writeImage(_:for:)`, `.trim()`, and `.clear()`.
- Produces: `MovieCachePolicy.maximumAge == 2_592_000` and `.maximumBytes == 157_286_400`.

- [ ] **Step 1: Add failing cache behavior tests using a temporary directory and injected clock**

```swift
func testMetadataCacheExpiresAfterThirtyDays() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var current = Date(timeIntervalSince1970: 1_000)
    let cache = MovieMetadataCache(root: root, now: { current })
    try cache.writeMetadata(.fixture(id: 550), tmdbID: 550)
    XCTAssertNotNil(try cache.readMetadata(tmdbID: 550))
    current.addTimeInterval(MovieCachePolicy.maximumAge + 1)
    XCTAssertNil(try cache.readMetadata(tmdbID: 550))
}

func testCacheEvictsLeastRecentlyUsedFilesUntilUnderLimit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var current = Date(timeIntervalSince1970: 1_000)
    let cache = MovieMetadataCache(root: root, maximumBytes: 10, now: { current })
    try cache.writeRaw(Data(repeating: 1, count: 6), key: "old")
    current.addTimeInterval(1)
    try cache.writeRaw(Data(repeating: 2, count: 6), key: "new")
    XCTAssertNil(cache.rawData(key: "old"))
    XCTAssertEqual(cache.rawData(key: "new")?.count, 6)
}
```

- [ ] **Step 2: Run cache tests and confirm missing-type failures**

Run: `swift test --package-path ReelAtlas-iOS --filter MovieMetadataCache`

Expected: compilation fails because cache types are absent.

- [ ] **Step 3: Implement atomic writes, schema-versioned names, corrupt-entry deletion, expiry, access-date refresh, and LRU trimming**

Use `Data.write(options: .atomic)` below `Application Support/ReelAtlas/MovieMetadata-v1`. Metadata keys are `movie-en-US-{tmdbID}.json`; image keys hash the resolved URL plus presentation size. Cleanup enumerates regular files, removes expired entries, and sorts survivors by access date then modification date before eviction.

- [ ] **Step 4: Run cache tests and the core suite**

Run: `swift test --package-path ReelAtlas-iOS`

Expected: expiry, corruption, atomic-write, and LRU tests pass.

- [ ] **Step 5: Commit cache implementation**

```bash
git add ReelAtlas-iOS/ReelAtlas/Core/MovieMetadataCache.swift ReelAtlas-iOS/ReelAtlas/Core/MovieCachePolicy.swift ReelAtlas-iOS/Tests/ReelAtlasCoreTests/CoreRulesTests.swift ReelAtlas-iOS/ReelSpan.xcodeproj/project.pbxproj
git commit -m "feat: cache requested movie metadata locally"
```

### Task 3: Build the cancellable metadata service and priority store

**Files:**
- Create: `ReelAtlas/Core/MovieMetadataService.swift`
- Create: `ReelAtlas/Core/MovieMetadataStore.swift`
- Modify: `Tests/ReelAtlasCoreTests/CoreRulesTests.swift`
- Modify: `ReelSpan.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: request/models/cache from Tasks 1–2.
- Produces: `MovieMetadataService.metadata(tmdbID:)`, `.search(query:page:)`, and `.imageData(url:)`.
- Produces: `MovieMetadataStore.beginVisible(_:)`, `.endVisible(_:)`, `.beginDetail(_:)`, `.endDetail(_:)`, `.metadataState(for:)`, and `.search(query:page:)`.

- [ ] **Step 1: Add failing transport/error/cancellation/deduplication/priority tests**

```swift
func testServiceMaps429WithoutRetryLoop() async {
    let transport = StaticHTTPTransport(status: 429, data: Data())
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = MovieMetadataService(transport: transport, cache: MovieMetadataCache(root: root))
    do {
        _ = try await service.metadata(tmdbID: 550)
        XCTFail("Expected rate-limited response")
    } catch {
        XCTAssertEqual(error as? MovieMetadataError, .rateLimited)
    }
    XCTAssertEqual(await transport.requests.count, 1)
}

func testDetailCancelsQueuedRowsAndRunsFirst() async throws {
    let scheduler = MovieRequestScheduler(maximumListRequests: 2)
    let first = scheduler.enqueueList(id: 1)
    let queued = scheduler.enqueueList(id: 2)
    let detail = scheduler.beginDetail(id: 3)
    XCTAssertTrue(queued.isCancelled)
    XCTAssertEqual(await scheduler.nextStartedID(), 3)
    _ = (first, detail)
}
```

The test file defines this exact external-boundary double and asserts only the service's observable result and request count:

```swift
actor StaticHTTPTransport: MovieHTTPTransport {
    let status: Int
    let data: Data
    private(set) var requests: [URLRequest] = []

    init(status: Int, data: Data) {
        self.status = status
        self.data = data
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (data, response)
    }
}
```

- [ ] **Step 2: Run focused tests and confirm missing-type failures**

Run: `swift test --package-path ReelAtlas-iOS --filter 'MovieMetadataService|DetailCancels|RequestScheduler'`

Expected: compilation fails for the service/store/scheduler types.

- [ ] **Step 3: Implement an injected async transport and explicit error mapping**

```swift
protocol MovieHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

enum MovieMetadataError: Error, Equatable {
    case offline, timedOut, notFound, rateLimited, server(Int), invalidResponse, decoding
}
```

Use a 12-second request timeout. Map `URLError.cancelled` to `CancellationError`, `.notConnectedToInternet` to `.offline`, `.timedOut` to `.timedOut`, 404 to `.notFound`, 429 to `.rateLimited`, and 500–599 to `.server(status)`. Do not automatically loop on 429 or 5xx.

- [ ] **Step 4: Implement cache-first fetches, request deduplication, one-second row dwell, two-list concurrency, and detail suspension**

The store holds one task per `tmdbID`, shares it between active consumers, cancels when the last consumer disappears, and publishes a result only if the request generation still matches. Detail begins at `.userInitiated`, cancels queued list work, and prevents new list starts until `endDetail`.

- [ ] **Step 5: Run focused cancellation tests and the complete suite**

Run: `swift test --package-path ReelAtlas-iOS`

Expected: all service, cache, cancellation, concurrency, and priority tests pass.

- [ ] **Step 6: Commit service and scheduling**

```bash
git add ReelAtlas-iOS/ReelAtlas/Core/MovieMetadataService.swift ReelAtlas-iOS/ReelAtlas/Core/MovieMetadataStore.swift ReelAtlas-iOS/Tests/ReelAtlasCoreTests/CoreRulesTests.swift ReelAtlas-iOS/ReelSpan.xcodeproj/project.pbxproj
git commit -m "feat: schedule cancellable movie metadata requests"
```

### Task 4: Backfill missing TMDB IDs from Wikidata

**Files:**
- Create: `Scripts/backfill_tmdb_ids.py`
- Create: `Scripts/tests/test_backfill_tmdb_ids.py`
- Create at execution: `Artifacts/tmdb-id-backfill-report.json`
- Modify at execution: `Data/content_seed.sqlite`
- Modify at execution: `ReelAtlas/Resources/content_seed.sqlite`

**Interfaces:**
- Consumes: movie QIDs and current `tmdb_movie_id` values.
- Produces: validated `P4947` mappings and a deterministic JSON audit.

- [ ] **Step 1: Add failing parser and conflict tests**

```python
def test_extracts_single_positive_p4947_claim(self):
    entity = {"claims": {"P4947": [{"mainsnak": {"datavalue": {"value": "550"}}}]}}
    self.assertEqual(extract_tmdb_id(entity), 550)

def test_rejects_conflicting_p4947_claims(self):
    entity = {"claims": {"P4947": [claim("550"), claim("551")]}}
    self.assertEqual(extract_tmdb_id(entity), Conflict(values=[550, 551]))
```

- [ ] **Step 2: Run the parser tests and confirm import failure**

Run: `python3 -m unittest ReelAtlas-iOS/Scripts/tests/test_backfill_tmdb_ids.py -v`

Expected: failure because `backfill_tmdb_ids` does not exist.

- [ ] **Step 3: Implement batched Wikidata entity requests and transactional updates**

Use `https://www.wikidata.org/w/api.php?action=wbgetentities&props=claims&format=json&ids=...` in batches of 50 QIDs with an explicit user agent, bounded retry for network/429/5xx, and resume data in `Artifacts`. Update only null `tmdb_movie_id` rows with one positive `P4947` value. Record conflicts and failures without guessing.

- [ ] **Step 4: Run script unit tests**

Run: `python3 -m unittest discover -s ReelAtlas-iOS/Scripts/tests -v`

Expected: parser, batching, resume, transaction, and existing importer tests pass.

- [ ] **Step 5: Run the backfill against the canonical database and generate the audit**

Run: `python3 ReelAtlas-iOS/Scripts/backfill_tmdb_ids.py --database ReelAtlas-iOS/Data/content_seed.sqlite --report ReelAtlas-iOS/Artifacts/tmdb-id-backfill-report.json`

Expected: report starts from 3,162 missing IDs, lists every mapping/conflict/unresolved QID, and database integrity remains `ok`.

- [ ] **Step 6: Copy the verified canonical database through the project database-generation command and audit duplicates**

Run: `sqlite3 ReelAtlas-iOS/Data/content_seed.sqlite 'PRAGMA integrity_check; SELECT COUNT(*),SUM(tmdb_movie_id IS NULL) FROM movies; SELECT COUNT(*) FROM (SELECT tmdb_movie_id FROM movies WHERE tmdb_movie_id IS NOT NULL GROUP BY tmdb_movie_id HAVING COUNT(*)>1);'`

Expected: integrity is `ok`; remaining missing IDs, the ten baseline duplicate TMDB-ID groups, and any additional duplicates introduced by verified Wikidata claims are explicitly recorded before slimming.

- [ ] **Step 7: Commit the repeatable backfill tooling and report**

```bash
git add ReelAtlas-iOS/Scripts/backfill_tmdb_ids.py ReelAtlas-iOS/Scripts/tests/test_backfill_tmdb_ids.py ReelAtlas-iOS/Artifacts/tmdb-id-backfill-report.json ReelAtlas-iOS/Data/content_seed.sqlite
git commit -m "data: backfill TMDB ids from Wikidata"
```

### Task 5: Remove bundled TMDB metadata from the data pipeline and app resources

**Files:**
- Modify: `Data/schema.sql`
- Modify: `ReelAtlas/Resources/schema.sql`
- Modify: `Scripts/import_csv.py`
- Modify: `Scripts/tests/test_import_csv.py`
- Create: `Scripts/slim_content_database.py`
- Create: `Scripts/tests/test_slim_content_database.py`
- Modify: `Data/content_seed.sqlite`
- Modify: `ReelAtlas/Resources/content_seed.sqlite`
- Modify: `ReelSpan.xcodeproj/project.pbxproj`
- Remove: `Data/ContentText_en.sqlite`
- Remove: `Data/ContentText_zh-Hans.sqlite`
- Remove: `ReelAtlas/Resources/ContentText_en.sqlite`
- Remove: `ReelAtlas/Resources/ContentText_zh-Hans.sqlite`
- Remove: `ReelAtlas/Resources/SmallPosters/`
- Remove: `ReelAtlas/Data/MovieTextStore.swift`

**Interfaces:**
- Produces bundled `movies(id, movie_qid, imdb_id, tmdb_movie_id)` plus existing ReelSpan-owned relational tables.
- Preserves all story-time/location/source/confidence row counts and foreign-key validity.

- [ ] **Step 1: Add failing slim-database audit tests**

```python
PROHIBITED_MOVIE_COLUMNS = {
    "title_en", "title_zh", "labels_json", "release_date", "release_year",
    "directors_json", "origin_countries_json", "genres_json", "runtime", "image",
    "tmdb_overview", "tmdb_tagline", "overview_en",
}

def test_slim_database_keeps_identity_without_tmdb_metadata(self):
    columns = set(table_columns(self.output, "movies"))
    self.assertEqual(columns, {"id", "movie_qid", "imdb_id", "tmdb_movie_id"})
    self.assertTrue(columns.isdisjoint(PROHIBITED_MOVIE_COLUMNS))
```

- [ ] **Step 2: Run importer/slimming tests and confirm the prohibited columns remain**

Run: `python3 -m unittest discover -s ReelAtlas-iOS/Scripts/tests -v`

Expected: new slim schema assertion fails against current schema.

- [ ] **Step 3: Implement the slim schema and transactional database transformer**

Create a new database from the slim schema, copy identity and every ReelSpan table inside one transaction, run `foreign_key_check` and `integrity_check`, and replace output atomically only after validation. Resolve duplicate `tmdb_id` mappings by retaining both identities; runtime reverse lookup returns the first deterministic local identity while location-driven rows remain distinct.

- [ ] **Step 4: Update CSV import so legacy input columns can be read but prohibited fields are not inserted into output**

Keep source-header validation compatible with the current archives, project only `movie_qid`, generated stable `id`, `imdb_id`, and `tmdb_movie_id` into `movies`, and preserve all nonmovie tables unchanged.

- [ ] **Step 5: Generate both canonical and bundled slim databases, then remove language databases and bundled posters from the Xcode resource phase**

Run: `python3 ReelAtlas-iOS/Scripts/slim_content_database.py --input ReelAtlas-iOS/Data/content_seed.sqlite --output /tmp/reelspan-content-slim.sqlite --resource-output ReelAtlas-iOS/ReelAtlas/Resources/content_seed.sqlite`

Expected: the resource database has exactly four movie columns and no poster/language-pack resource references remain in `project.pbxproj`.

- [ ] **Step 6: Run the full pipeline tests and resource audit**

Run: `python3 -m unittest discover -s ReelAtlas-iOS/Scripts/tests -v`

Run: `sqlite3 ReelAtlas-iOS/ReelAtlas/Resources/content_seed.sqlite 'PRAGMA integrity_check; PRAGMA foreign_key_check; PRAGMA table_info(movies); SELECT COUNT(*) FROM movies;'`

Expected: all tests pass, integrity is `ok`, foreign-key output is empty, movie count is 49,995, and only four identity columns are listed.

- [ ] **Step 7: Commit the slim data bundle**

```bash
git add ReelAtlas-iOS/Data/schema.sql ReelAtlas-iOS/ReelAtlas/Resources/schema.sql ReelAtlas-iOS/Scripts ReelAtlas-iOS/Data/content_seed.sqlite ReelAtlas-iOS/ReelAtlas/Resources/content_seed.sqlite ReelAtlas-iOS/ReelSpan.xcodeproj/project.pbxproj
git add -u ReelAtlas-iOS/Data ReelAtlas-iOS/ReelAtlas/Resources ReelAtlas-iOS/ReelAtlas/Data/MovieTextStore.swift
git commit -m "refactor: remove bundled TMDB movie metadata"
```

### Task 6: Adapt the existing presentation model to slim local records

**Files:**
- Modify: `ReelAtlas/Data/AppModels.swift`
- Modify: `ReelAtlas/Data/ContentRepository.swift`
- Modify: `ReelAtlas/App/AppModel.swift`
- Modify: `Package.swift`
- Modify: `Tests/ReelAtlasCoreTests/CoreRulesTests.swift`
- Modify: `Tests/ReelAtlasCoreTests/TestFixtures.swift`

**Interfaces:**
- Consumes: slim database and `MovieMetadata`.
- Produces: the existing `MovieViewData` populated from local identity/story fields and empty metadata placeholders, then enriched by `MovieMetadata` at runtime.
- Produces: `ContentRepository.movie(id:)` and `.movie(tmdbID:)` without local title/metadata reads.

- [ ] **Step 1: Add failing composition tests**

```swift
func testBaseMovieKeepsStoryDataWithMetadataPlaceholders() {
    let movie = MovieViewData.baseFixture(tmdbID: nil)
    XCTAssertEqual(movie.locations.first?.name, "Beijing")
    XCTAssertEqual(movie.title, "")
    XCTAssertTrue(movie.genres.isEmpty)
}

func testEnrichmentKeepsStoryDataAndUsesWorkerMetadata() {
    let movie = MovieViewData.baseFixture(tmdbID: 550)
    let enriched = movie.enriching(with: MovieMetadata.fixture(id: 550))
    XCTAssertEqual(enriched.title, "Fight Club")
    XCTAssertEqual(enriched.timeRanges.first?.startYear, 1990)
}
```

Extend the shared test fixture with a literal base record; this is test-only construction, not production fallback data:

```swift
extension MovieViewData {
    static func baseFixture(tmdbID: Int?) -> Self {
        .init(
            id: 1, movieQID: "Q1", imdbID: "tt0137523", tmdbID: tmdbID,
            title: "", overview: "", tagline: "", overviewSource: "",
            overviewSourceTitle: "", overviewSourceURL: "", overviewLicense: "",
            releaseDate: nil, releaseYear: nil, runtimeMinutes: nil, sourceImage: nil,
            originalLanguage: "", rating: 0, voteCount: 0, rankingScore: 0,
            smallPosterFilename: nil, largePosterURL: nil, backdropURL: nil,
            director: nil, originCountries: [], isDocumentary: false, genres: [],
            timeRanges: [.init(startYear: 1990, endYear: 1999)],
            locations: [.init(rawPlaceQID: "Q956", name: "Beijing")], cast: []
        )
    }
}
```

- [ ] **Step 2: Run focused tests and confirm the old mixed model cannot express the contract**

Run: `swift test --package-path ReelAtlas-iOS --filter Presentation`

Expected: the base-placeholder and Worker-enrichment expectations fail against the current local metadata mapper.

- [ ] **Step 3: Preserve `MovieViewData`, update its Worker enrichment, and rewrite repository SQL for the four-column movie table**

Repository-created values keep their current IDs, QIDs, IMDb/TMDB IDs, time ranges, and locations while using empty/nil metadata fields until enrichment. Remove local movie-title search and metadata-dependent ordering. Location/time searches return stable records ordered by ReelSpan confidence and internal ID. Add `tmdb_movie_id` lookup for attaching local story data to Worker search results.

Update the Swift package target path/source list to include `Data/AppModels.swift` and `App/L10n.swift` alongside `Core`, so the real enrichment implementation is compiled by these tests rather than mirrored in a test helper.

- [ ] **Step 4: Replace `ImageDownloadManager` ownership with one `MovieMetadataStore` in `AppModel` and stop iCloud metadata-cache backup**

Favorites continue to use stable internal IDs/QIDs. iCloud backup keeps favorites and language preference only; it does not copy runtime metadata or images.

- [ ] **Step 5: Run core tests and compile the app to expose all remaining mixed-model call sites**

Run: `swift test --package-path ReelAtlas-iOS`

Run: `xcodebuild -project ReelAtlas-iOS/ReelSpan.xcodeproj -scheme ReelSpan -sdk iphonesimulator -configuration Debug build CODE_SIGNING_ALLOWED=NO`

Expected: core tests pass; any compile errors point only to views scheduled for Tasks 7–8 and are recorded before continuing.

- [ ] **Step 6: Commit the local/runtime model boundary**

```bash
git add ReelAtlas-iOS/ReelAtlas/Data/AppModels.swift ReelAtlas-iOS/ReelAtlas/Data/ContentRepository.swift ReelAtlas-iOS/ReelAtlas/App/AppModel.swift ReelAtlas-iOS/Package.swift ReelAtlas-iOS/Tests/ReelAtlasCoreTests/CoreRulesTests.swift ReelAtlas-iOS/Tests/ReelAtlasCoreTests/TestFixtures.swift
git commit -m "refactor: separate movie story data from metadata"
```

### Task 7: Replace blocking movie search with a latest-query Worker session

**Files:**
- Modify: `ReelAtlas/Core/ResultsDrawerState.swift`
- Modify: `ReelAtlas/App/AppModel.swift`
- Modify: `ReelAtlas/Features/Home/HomeView.swift`
- Modify: `Tests/ReelAtlasCoreTests/CoreRulesTests.swift`

**Interfaces:**
- Consumes: `MovieMetadataStore.search(query:page:)` and repository TMDB-ID lookup.
- Produces: `MovieSearchSession` with synchronous `updateQuery(_:)`, cancellable 250 ms debounce, and generation-checked publication.

- [ ] **Step 1: Add failing rapid-input regression tests**

```swift
func testLaterSearchQueryPublishesWithoutWaitingForObsoleteResult() async {
    let transport = ControllableSearchTransport()
    let session = MovieSearchSession(search: transport.search)
    session.updateQuery("Ca")
    session.updateQuery("Casa")
    await transport.complete(query: "Casa", titles: ["Casablanca"])
    XCTAssertEqual(session.results.map(\.title), ["Casablanca"])
    await transport.complete(query: "Ca", titles: ["Older"])
    XCTAssertEqual(session.results.map(\.title), ["Casablanca"])
}

func testFirstCandidateArrivalDoesNotChangeEditingState() {
    var state = SearchFieldState(text: "Casa", isFocused: true, selection: 4..<4)
    state.receiveResults(count: 1)
    XCTAssertTrue(state.isFocused)
    XCTAssertEqual(state.selection, 4..<4)
}
```

`ControllableSearchTransport` is a test actor with `search(query:)` storing one checked continuation per normalized query and `complete(query:titles:)` resuming exactly that query. Its recorded `cancelledQueries` collection verifies that `"Ca"` is cancelled when `"Casa"` arrives.

- [ ] **Step 2: Run search tests and verify the old actor pipeline fails the desired contract**

Run: `swift test --package-path ReelAtlas-iOS --filter Search`

Expected: new session/focus tests fail before production changes.

- [ ] **Step 3: Instrument the existing input path and record the main-thread blocker**

Add temporary signposts around `DynamicReturnKeyTextField.textChanged`, `HomeView` suggestion derivation, local place matching, and candidate publication. Reproduce rapid typing through the first movie hit in Simulator and save the trace summary in the implementation notes. Remove temporary signposts after the root cause is identified.

- [ ] **Step 4: Remove `MovieSearchWorker` and local metadata search, then implement latest-query remote search**

Every text change synchronously updates text and generation, cancels the old debounce/request, and schedules a new request after 250 ms. The result handler checks normalized query plus generation before publishing. Place suggestions are computed outside SwiftUI `body` and cached per query so rendering cannot scan SQLite on the main thread.

- [ ] **Step 5: Stabilize the UIKit text-field bridge and suggestion container identity**

`updateUIView` never resigns or reloads the field because result arrays changed. It preserves marked text and selection during Chinese/IME composition, applies external text only when it differs outside active composition, and changes the return key without replacing the `UITextField`.

- [ ] **Step 6: Run rapid-input tests and app build**

Run: `swift test --package-path ReelAtlas-iOS --filter Search`

Run: `xcodebuild -project ReelAtlas-iOS/ReelSpan.xcodeproj -scheme ReelSpan -sdk iphonesimulator -configuration Debug build CODE_SIGNING_ALLOWED=NO`

Expected: latest-query and focus/selection tests pass; build exits 0.

- [ ] **Step 7: Commit the search fix**

```bash
git add ReelAtlas-iOS/ReelAtlas/Core/ResultsDrawerState.swift ReelAtlas-iOS/ReelAtlas/App/AppModel.swift ReelAtlas-iOS/ReelAtlas/Features/Home/HomeView.swift ReelAtlas-iOS/Tests/ReelAtlasCoreTests/CoreRulesTests.swift
git commit -m "fix: keep movie search input responsive"
```

### Task 8: Migrate drawer, favorites, posters, and native detail UI

**Files:**
- Modify: `ReelAtlas/Features/Home/HomeView.swift`
- Modify: `ReelAtlas/Features/Home/MovieRowView.swift`
- Modify: `ReelAtlas/Features/Home/LocalPosterView.swift`
- Modify: `ReelAtlas/Features/MovieDetail/MovieArtworkView.swift`
- Modify: `ReelAtlas/Features/MovieDetail/MovieDetailView.swift`
- Create: `ReelAtlas/Core/MovieDetailPresentation.swift`
- Modify: `ReelAtlas/Resources/Localizable.xcstrings`
- Remove: `ReelAtlas/Services/ImageDownloadManager.swift`
- Modify: `ReelSpan.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `MovieViewData` and `MovieMetadataStore` states.
- Produces: native detail navigation from drawer/favorites/search and lifecycle-owned row/detail loads.

- [ ] **Step 1: Add failing pure presentation tests for multiple directors, empty overview/cast, and IMDb fallback**

```swift
func testDetailPresentationJoinsMultipleDirectors() {
    let metadata = MovieMetadata.fixture(directors: [.fixture(name: "A"), .fixture(name: "B")])
    let movie = MovieViewData.baseFixture(tmdbID: metadata.id).enriching(with: metadata)
    XCTAssertEqual(MovieDetailPresentation(movie: movie).directorText, "A · B")
}

func testMissingMetadataLeavesStoryCardsAvailable() {
    let detail = MovieDetailPresentation(movie: .baseFixture(tmdbID: nil))
    XCTAssertEqual(detail.overviewText, L10n.text("movie.overview.unavailable"))
    XCTAssertFalse(detail.storyLocationText.isEmpty)
}
```

- [ ] **Step 2: Run detail presentation tests and confirm missing presentation behavior**

Run: `swift test --package-path ReelAtlas-iOS --filter DetailPresentation`

Expected: failure because the presentation adapter is absent.

- [ ] **Step 3: Make rows load only after continuous visibility and render stable placeholders**

Rows use stable internal IDs, call `beginVisible` from lifecycle task ownership, call `endVisible` on disappearance, and render metadata state without changing row height. Poster display uses cached image data when present, Worker `posterUrl` after detail load, then validated search `posterPath`, then the existing placeholder.

- [ ] **Step 4: Restore all taps to the native detail page**

Replace `selectedDrawerIMDb`, `selectedSearchIMDb`, and favorites IMDb covers with one identifiable detail destination. Search results without a local match construct an identity with TMDB ID and empty story data; known results attach repository story data.

- [ ] **Step 5: Restore progressive detail metadata and lifecycle cancellation**

The detail appears immediately with story cards and metadata placeholders, calls `beginDetail` on entry, and calls `endDetail` on dismissal. It renders original title when different, overview/tagline, poster/backdrop, release/runtime/language/status, genres/rating, all directors, and bounded primary cast. It includes an explicit `Link` to IMDb and never auto-opens Safari.

- [ ] **Step 6: Delete the obsolete image/key manager and settings key UI, then add localized unavailable/retry/loading strings**

Remove Keychain storage, direct-IP transport, TMDB API settings copy, and cache-to-iCloud hooks. Keep a local runtime-cache clear action backed by `MovieMetadataCache.clear()`.

- [ ] **Step 7: Run tests, secret/host scans, and unsigned Simulator build**

Run: `swift test --package-path ReelAtlas-iOS`

Run: `rg -n 'api\.themoviedb\.org|tmdb\.xiaoguiwk\.top|api_key|read access token|KeychainAPIKeyStore|13\.224\.161\.90' ReelAtlas-iOS/ReelAtlas ReelAtlas-iOS/ReelSpan.xcodeproj`

Run: `xcodebuild -project ReelAtlas-iOS/ReelSpan.xcodeproj -scheme ReelSpan -sdk iphonesimulator -configuration Debug build CODE_SIGNING_ALLOWED=NO`

Expected: tests/build pass; scan has no matches. `image.tmdb.org` appears only in the central fallback builder.

- [ ] **Step 8: Commit the dynamic views and detail restoration**

```bash
git add ReelAtlas-iOS/ReelAtlas/Features ReelAtlas-iOS/ReelAtlas/Core/MovieDetailPresentation.swift ReelAtlas-iOS/ReelAtlas/Resources/Localizable.xcstrings ReelAtlas-iOS/ReelSpan.xcodeproj/project.pbxproj
git add -u ReelAtlas-iOS/ReelAtlas/Services/ImageDownloadManager.swift
git commit -m "feat: restore dynamic native movie details"
```

### Task 9: Add consumable StoreKit tips

**Files:**
- Create: `ReelAtlas/Core/TipSelection.swift`
- Create: `ReelAtlas/Features/MovieDetail/TipSheet.swift`
- Modify: `ReelAtlas/Services/PurchaseManager.swift`
- Modify: `ReelAtlas/Features/MovieDetail/MovieDetailView.swift`
- Modify: `ReelAtlas/Resources/Localizable.xcstrings`
- Create: `ReelAtlas/Resources/ReelSpan.storekit`
- Modify: `Tests/ReelAtlasCoreTests/CoreRulesTests.swift`
- Modify: `ReelSpan.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: the three Tip Product IDs and localized `displayPrice` presentation.
- Produces: `TipPurchaseManager.products`, `.load()`, and `.purchase(productID:)`.

- [ ] **Step 1: Add failing quantity-boundary tests**

```swift
func testTipSelectionAllowsOnlyStoreKitQuantityRange() {
    XCTAssertEqual(TipSelection.quickQuantities, [1, 3, 5])
    XCTAssertNil(TipSelection.validatedQuantity(0))
    XCTAssertEqual(TipSelection.validatedQuantity(7), 7)
    XCTAssertEqual(TipSelection.validatedQuantity(10), 10)
    XCTAssertNil(TipSelection.validatedQuantity(11))
}
```

- [ ] **Step 2: Run the test and confirm `TipSelection` is absent**

Run: `swift test --package-path ReelAtlas-iOS --filter TipSelection`

Expected: compilation fails for missing `TipSelection`.

- [ ] **Step 3: Implement selection rules and StoreKit purchase states**

```swift
static let tipProductIDs = [
    "com.xiaoguiwk.ReelSpan.tip.small",
    "com.xiaoguiwk.ReelSpan.tip.medium",
    "com.xiaoguiwk.ReelSpan.tip.large"
]

func purchaseTip(productID: String) async {
    guard let tipProduct = products[productID] else { return }
    let result = try await tipProduct.purchase()
    if case .success(.verified(let transaction)) = result {
        await transaction.finish()
    }
}
```

Do not grant an entitlement. Represent unavailable, purchasing, verified, pending, cancelled, unverified, restricted, and failed states separately.

- [ ] **Step 4: Build the tip sheet under Favorite with live localized totals**

The sheet shows one button for each configured Tip product and uses `Product.displayPrice` without hardcoded currency values. Cancellation closes or resets quietly; other failures show localized inline status.

- [ ] **Step 5: Add a local StoreKit configuration for the consumable base product and run build/tests**

Run: `swift test --package-path ReelAtlas-iOS`

Run: `xcodebuild -project ReelAtlas-iOS/ReelSpan.xcodeproj -scheme ReelSpan -sdk iphonesimulator -configuration Debug build CODE_SIGNING_ALLOWED=NO`

Expected: Tip Product ID/state tests pass and the app builds with StoreKit configuration included for local testing.

- [ ] **Step 6: Commit tip support**

```bash
git add ReelAtlas-iOS/ReelAtlas/Core/TipSelection.swift ReelAtlas-iOS/ReelAtlas/Features/MovieDetail ReelAtlas-iOS/ReelAtlas/Services/PurchaseManager.swift ReelAtlas-iOS/ReelAtlas/Resources ReelAtlas-iOS/Tests/ReelAtlasCoreTests/CoreRulesTests.swift ReelAtlas-iOS/ReelSpan.xcodeproj/project.pbxproj
git commit -m "feat: add optional StoreKit tips"
```

### Task 10: Perform end-to-end verification and produce the migration report

**Files:**
- Modify: `README.md`
- Modify: `docs/DATA_PIPELINE.md`
- Create: `Artifacts/dynamic-metadata-migration-report.md`

**Interfaces:**
- Consumes: all prior tasks and the Wikidata backfill report.
- Produces: the six-part delivery report requested by the user.

- [ ] **Step 1: Run every automated test from a clean invocation**

Run: `python3 -m unittest discover -s ReelAtlas-iOS/Scripts/tests -v`

Run: `swift test --package-path ReelAtlas-iOS`

Expected: both commands exit 0 with zero failed tests.

- [ ] **Step 2: Audit bundled database and resources**

Run: `sqlite3 ReelAtlas-iOS/ReelAtlas/Resources/content_seed.sqlite 'PRAGMA integrity_check; PRAGMA foreign_key_check; PRAGMA table_info(movies); SELECT COUNT(*) AS movies,SUM(tmdb_movie_id IS NULL) AS missing_tmdb FROM movies;'`

Run: `find ReelAtlas-iOS/ReelAtlas/Resources -type f | sort`

Expected: integrity `ok`, no foreign-key rows, only identity movie columns, and no movie metadata language databases or poster files.

- [ ] **Step 3: Audit all forbidden network and secret references**

Run: `rg -n 'api\.themoviedb\.org|tmdb\.xiaoguiwk\.top|api_key|TMDB.*KEY|READ_ACCESS_TOKEN|SUPABASE.*KEY|KeychainAPIKeyStore|13\.224\.161\.90' ReelAtlas-iOS --glob '!Artifacts/**' --glob '!.build/**'`

Expected: zero matches. Then verify `rg -n 'reelspan-tmdb\.xiaoguiwk\.workers\.dev' ReelAtlas-iOS/ReelAtlas` returns exactly the centralized request builder and `rg -n 'image\.tmdb\.org' ReelAtlas-iOS/ReelAtlas` returns exactly the centralized fallback builder.

- [ ] **Step 4: Build the complete app freshly**

Run: `xcodebuild -project ReelAtlas-iOS/ReelSpan.xcodeproj -scheme ReelSpan -sdk iphonesimulator -configuration Debug clean build CODE_SIGNING_ALLOWED=NO`

Expected: `** BUILD SUCCEEDED **` and exit code 0.

- [ ] **Step 5: Exercise the critical Simulator flows**

Verify rapid typing continues while movie candidates load; old results never replace a newer query; drawer and favorites rows load after dwell; opening detail preempts row work; leaving cancels detail work; cached content reopens offline; missing metadata keeps story cards visible; `posterUrl` wins over fallback; IMDb link opens only when tapped; each StoreKit Tip product completes correctly without creating an entitlement.

- [ ] **Step 6: Write the migration report and update documentation**

The report contains: modified files; new service/models; migrated pages; remaining old metadata dependencies (expected none); original/backfilled/unresolved TMDB-ID counts; duplicate mapping count; automated test totals; build output; and manual flow results. README and pipeline docs describe the Worker-only runtime contract and slim bundle.

- [ ] **Step 7: Review the requirement checklist line by line and commit verification artifacts**

```bash
git add ReelAtlas-iOS/README.md ReelAtlas-iOS/docs/DATA_PIPELINE.md ReelAtlas-iOS/Artifacts/dynamic-metadata-migration-report.md
git commit -m "docs: report dynamic metadata migration"
```
