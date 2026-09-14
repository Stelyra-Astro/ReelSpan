import XCTest
@testable import ReelAtlasCore

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
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

private struct FailingMovieTransport: MovieHTTPTransport {
    let code: URLError.Code
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(code)
    }
}

private actor DelayedMovieTransport: MovieHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var cancellations = 0
    let delay: Duration
    init(delay: Duration = .milliseconds(150)) { self.delay = delay }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        do { try await Task.sleep(for: delay) }
        catch { cancellations += 1; throw error }
        let id = Int(request.url!.lastPathComponent) ?? 550
        return (try JSONEncoder().encode(MovieMetadata.fixture(id: id)),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
final class MovieMetadataServiceTests: XCTestCase {
    private func waitFor(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for observable request state", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func cache() -> sending MovieMetadataCache {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return MovieMetadataCache(root: root)
    }

    func testServiceMapsHTTPFailuresWithoutRetryLoop() async {
        for (status, expected) in [(404, MovieMetadataError.notFound), (429, .rateLimited), (503, .server(503)), (403, .invalidResponse), (200, .decoding)] {
            let transport = StaticHTTPTransport(status: status, data: Data())
            let service = MovieMetadataService(transport: transport, cache: cache())
            do { _ = try await service.metadata(tmdbID: 550); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? MovieMetadataError, expected) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.timeoutInterval, 12)
        }
    }

    func testServiceMapsOfflineTimeoutAndCancellation() async {
        for (code, expected) in [(URLError.notConnectedToInternet, MovieMetadataError.offline), (.timedOut, .timedOut)] {
            let service = MovieMetadataService(transport: FailingMovieTransport(code: code), cache: cache())
            do { _ = try await service.metadata(tmdbID: 550); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? MovieMetadataError, expected) }
        }
        let service = MovieMetadataService(transport: FailingMovieTransport(code: .cancelled), cache: cache())
        do { _ = try await service.metadata(tmdbID: 550); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testServiceUsesDiskMetadataAndImageCacheBeforeTransport() async throws {
        let disk = cache()
        try disk.writeMetadata(.fixture(id: 550), tmdbID: 550)
        let url = URL(string: "https://image.tmdb.org/t/p/w185/test.jpg")!
        try disk.writeImage(Data([1, 2]), for: url)
        let transport = StaticHTTPTransport(status: 503, data: Data())
        let service = MovieMetadataService(transport: transport, cache: disk)
        let metadata = try await service.metadata(tmdbID: 550)
        let image = try await service.imageData(url: url)
        XCTAssertEqual(metadata.id, 550)
        XCTAssertEqual(image, Data([1, 2]))
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testServiceDeduplicatesAndKeepsOtherConsumerAlive() async throws {
        let transport = DelayedMovieTransport()
        let service = MovieMetadataService(transport: transport, cache: cache())
        let first = Task { try await service.metadata(tmdbID: 550) }
        let second = Task { try await service.metadata(tmdbID: 550) }
        try await Task.sleep(for: .milliseconds(30))
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let result = try await second.value
        XCTAssertEqual(result.id, 550)
        let count = await transport.requests.count
        let cancellations = await transport.cancellations
        XCTAssertEqual(count, 1)
        XCTAssertEqual(cancellations, 0)
        _ = try await service.metadata(tmdbID: 550)
        let cachedCount = await transport.requests.count
        XCTAssertEqual(cachedCount, 1)
    }

    func testServiceLastConsumerCancellationReachesTransport() async throws {
        let transport = DelayedMovieTransport(delay: .seconds(30))
        let service = MovieMetadataService(transport: transport, cache: cache())
        let request = Task { try await service.metadata(tmdbID: 550) }
        try await waitFor { await transport.requests.count == 1 }
        request.cancel()
        do { _ = try await request.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await waitFor { await transport.cancellations == 1 }
        let cancellations = await transport.cancellations
        XCTAssertEqual(cancellations, 1)
    }

    func testServiceSearchDecodesPageAndUsesFixedWorkerLanguage() async throws {
        let data = Data(#"{"page":2,"results":[],"totalPages":3,"totalResults":40}"#.utf8)
        let transport = StaticHTTPTransport(status: 200, data: data)
        let service = MovieMetadataService(transport: transport, cache: cache())
        let page = try await service.search(query: " Fight Club ", page: 2)
        XCTAssertEqual(page.totalPages, 3)
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.url?.host, "reelspan-tmdb.xiaoguiwk.workers.dev")
        let items = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "language" }?.value, "en-US")
        XCTAssertEqual(items.first { $0.name == "query" }?.value, "Fight Club")
    }

    func testStoreRowDwellAndLastConsumerCancellation() async throws {
        let transport = DelayedMovieTransport(delay: .seconds(30))
        let store = MovieMetadataStore(service: MovieMetadataService(transport: transport, cache: cache()))
        store.beginVisible(550)
        try await Task.sleep(for: .milliseconds(100))
        let beforeDwell = await transport.requests.count
        XCTAssertEqual(beforeDwell, 0)
        store.endVisible(550)
        try await Task.sleep(for: .milliseconds(1000))
        let afterDisappear = await transport.requests.count
        XCTAssertEqual(afterDisappear, 0)
        XCTAssertEqual(store.metadataState(for: 550), .idle)
        store.beginDetail(550)
        store.beginVisible(550)
        try await waitFor { await transport.requests.count == 1 }
        store.endDetail(550)
        let sharedCount = await transport.requests.count
        XCTAssertEqual(sharedCount, 1)
        store.endVisible(550)
        try await waitFor { await transport.cancellations == 1 }
        let cancellations = await transport.cancellations
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(store.metadataState(for: 550), .idle)
    }

    func testDetailCancelsQueuedRowsAndSuspendsNewListStarts() async throws {
        let transport = DelayedMovieTransport(delay: .milliseconds(400))
        let store = MovieMetadataStore(service: MovieMetadataService(transport: transport, cache: cache()), rowDwell: .zero)
        store.beginVisible(1)
        store.beginVisible(2)
        try await waitFor { await transport.requests.count == 2 }
        let initial = await transport.requests
        XCTAssertEqual(Set(initial.map { $0.url!.lastPathComponent }), ["1", "2"])
        store.beginVisible(3)
        try await Task.sleep(for: .milliseconds(30))
        store.beginDetail(4)
        store.beginVisible(5)
        try await Task.sleep(for: .milliseconds(500))
        let duringDetail = await transport.requests
        XCTAssertEqual(duringDetail.map { $0.url!.lastPathComponent }.sorted(), ["1", "2", "4"])
        XCTAssertEqual(store.metadataState(for: 4), .loaded(.fixture(id: 4)))
        store.endDetail(4)
        try await waitFor { store.metadataState(for: 3).metadata != nil && store.metadataState(for: 5).metadata != nil }
        XCTAssertEqual(store.metadataState(for: 3), .loaded(.fixture(id: 3)))
        XCTAssertEqual(store.metadataState(for: 5), .loaded(.fixture(id: 5)))
        for id in 1...5 { store.endVisible(id) }
    }

    func testStoreReappearingGenerationPublishesNewRequest() async throws {
        let transport = DelayedMovieTransport()
        let store = MovieMetadataStore(service: MovieMetadataService(transport: transport, cache: cache()), rowDwell: .zero)
        store.beginVisible(550)
        try await Task.sleep(for: .milliseconds(30))
        store.endVisible(550)
        store.beginDetail(550)
        try await waitFor { store.metadataState(for: 550).metadata != nil }
        XCTAssertEqual(store.metadataState(for: 550), .loaded(.fixture(id: 550)))
        store.endDetail(550)
    }

    func testStoreReleaseCancelsOwnedTransportTask() async throws {
        let transport = DelayedMovieTransport(delay: .seconds(30))
        var store: MovieMetadataStore? = MovieMetadataStore(service: MovieMetadataService(transport: transport, cache: cache()))
        store?.beginDetail(550)
        try await waitFor { await transport.requests.count == 1 }
        store = nil
        try await waitFor { await transport.cancellations == 1 }
        let cancellations = await transport.cancellations
        XCTAssertEqual(cancellations, 1)
    }

    func testStoreRepeatedVisibleConsumersShareUntilLastDisappears() async throws {
        let transport = DelayedMovieTransport(delay: .seconds(30))
        let store = MovieMetadataStore(service: MovieMetadataService(transport: transport, cache: cache()), rowDwell: .zero)
        store.beginVisible(550)
        store.beginVisible(550)
        try await waitFor { await transport.requests.count == 1 }
        store.endVisible(550)
        try await Task.sleep(for: .milliseconds(40))
        let count = await transport.requests.count
        let beforeLast = await transport.cancellations
        XCTAssertEqual(count, 1)
        XCTAssertEqual(beforeLast, 0)
        store.endVisible(550)
        try await waitFor { await transport.cancellations == 1 }
        let afterLast = await transport.cancellations
        XCTAssertEqual(afterLast, 1)
    }

    func testStoreDetailPromotesSameRowBeforeDwellAndPublishesFailure() async throws {
        let transport = StaticHTTPTransport(status: 429, data: Data())
        let store = MovieMetadataStore(service: MovieMetadataService(transport: transport, cache: cache()))
        store.beginVisible(550)
        store.beginDetail(550)
        try await waitFor { store.metadataState(for: 550) == .failed(.rateLimited) }
        XCTAssertEqual(store.metadataState(for: 550), .failed(.rateLimited))
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
        store.endVisible(550)
        store.endDetail(550)
    }

    func testServiceImageDownloadIsPersistedAndSearchCancellationPropagates() async throws {
        let transport = StaticHTTPTransport(status: 200, data: Data([1, 2, 3]))
        let service = MovieMetadataService(transport: transport, cache: cache())
        let url = URL(string: "https://image.tmdb.org/t/p/w185/test.jpg")!
        let first = try await service.imageData(url: url)
        let second = try await service.imageData(url: url)
        XCTAssertEqual(first, Data([1, 2, 3]))
        XCTAssertEqual(second, first)
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)

        let delayed = DelayedMovieTransport(delay: .seconds(30))
        let searchService = MovieMetadataService(transport: delayed, cache: cache())
        let task = Task { try await searchService.search(query: "Fight Club") }
        try await waitFor { await delayed.requests.count == 1 }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cancellations = await delayed.cancellations
        XCTAssertEqual(cancellations, 1)
    }

    func testRequestSchedulerCancelsQueuedWorkAndReusesReleasedPermit() async throws {
        let scheduler = MovieRequestScheduler(maximumListRequests: 1)
        let first = UUID()
        try await scheduler.acquireList(id: 1, token: first)
        let queued = Task { try await scheduler.acquireList(id: 2, token: UUID()) }
        try await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        do { try await queued.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        scheduler.releaseList(token: first)
        let next = UUID()
        try await scheduler.acquireList(id: 3, token: next)
        XCTAssertTrue(scheduler.isRunning(id: 3))
        XCTAssertFalse(scheduler.isRunning(id: 2))
        scheduler.releaseList(token: next)
    }
}

final class CoreRulesTests: XCTestCase {
    func testGenreDisplayNameRemovesOnlyTrailingFilmDescriptor() {
        XCTAssertEqual(GenreDisplayName.normalized("drama film"), "drama")
        XCTAssertEqual(GenreDisplayName.normalized("children's film"), "children's")
        XCTAssertEqual(GenreDisplayName.normalized("Film noir"), "Film noir")
        XCTAssertEqual(GenreDisplayName.normalized("political drama"), "political drama")
    }

    func testGenreLocalizationKeyAcceptsLowercaseSourceNamesAfterRemovingFilm() {
        XCTAssertEqual(GenreDisplayName.localizationKey(for: "drama film"), "genre.drama")
        XCTAssertEqual(GenreDisplayName.localizationKey(for: "Action Film"), "genre.action")
        XCTAssertNil(GenreDisplayName.localizationKey(for: "political drama"))
    }

    func testIMDbDestinationUsesTitlePageWhenIdentifierExists() {
        XCTAssertEqual(
            IMDbDestination.url(imdbID: "tt0099426", title: "Bullet in the Head").absoluteString,
            "https://www.imdb.com/title/tt0099426/"
        )
    }

    func testIMDbDestinationFallsBackToTitleSearchWhenIdentifierIsMissingOrInvalid() {
        XCTAssertEqual(
            IMDbDestination.url(imdbID: nil, title: "The Last Emperor").absoluteString,
            "https://www.imdb.com/find/?q=The%20Last%20Emperor&s=tt"
        )
        XCTAssertEqual(
            IMDbDestination.url(imdbID: "Q123", title: "Example").absoluteString,
            "https://www.imdb.com/find/?q=Example&s=tt"
        )
    }

    func testPublishedSupportLinksUseStelyraAstroPagesAndEmail() {
        XCTAssertEqual(ReelSpanLinks.website.absoluteString, "https://stelyra-astro.github.io/ReelSpan/")
        XCTAssertEqual(ReelSpanLinks.privacy.absoluteString, "https://stelyra-astro.github.io/ReelSpan/privacy/")
        XCTAssertEqual(ReelSpanLinks.terms.absoluteString, "https://stelyra-astro.github.io/ReelSpan/terms/")
        XCTAssertEqual(ReelSpanLinks.supportEmail, "Stelyra-Astro@proton.me")
        XCTAssertEqual(ReelSpanLinks.supportEmailURL.absoluteString, "mailto:Stelyra-Astro@proton.me")
    }

    func testICloudBackupManifestUsesStableMovieQIDsAndExcludesSecrets() throws {
        let manifest = ICloudBackupManifest(
            favoriteMovieQIDs: ["Q2", "Q1"],
            interfaceLanguage: "zh-Hans",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let data = try JSONEncoder().encode(manifest)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(manifest.favoriteMovieQIDs, ["Q1", "Q2"])
        XCTAssertFalse(text.localizedCaseInsensitiveContains("apiKey"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("content.sqlite"))
    }

    func testMapLookupTreatsNoResultAndCancellationAsNonFatal() {
        XCTAssertTrue(MapLookupErrorPolicy.isNonFatal(domain: "kCLErrorDomain", code: 8))
        XCTAssertTrue(MapLookupErrorPolicy.isNonFatal(domain: "kCLErrorDomain", code: 10))
        XCTAssertFalse(MapLookupErrorPolicy.isNonFatal(domain: "kCLErrorDomain", code: 2))
        XCTAssertFalse(MapLookupErrorPolicy.isNonFatal(domain: "Other", code: 8))
    }

    func testResultsDrawerHidesForSearchAndReturnsToMediumAfterResults() {
        var drawer = ResultsDrawerState()
        XCTAssertEqual(drawer.level, .medium)

        drawer.searchFocused()
        XCTAssertEqual(drawer.level, .hidden)

        drawer.searchFinished()
        XCTAssertEqual(drawer.level, .medium)
    }

    func testResultsDrawerCanRestAtTipAndExpandToFull() {
        var drawer = ResultsDrawerState()

        drawer.move(to: .tip)
        XCTAssertEqual(drawer.level, .tip)

        drawer.move(to: .full)
        XCTAssertEqual(drawer.level, .full)
    }

    func testMapNavigationCollapsesDrawerWithoutReopeningItAfterFocusUpdate() {
        var drawer = ResultsDrawerState()
        drawer.mapNavigationStarted()
        XCTAssertEqual(drawer.level, .tip)

        drawer.mapFocusUpdated()
        XCTAssertEqual(drawer.level, .tip)
    }

    func testManualDrawerCollapsePersistsUntilResultsAreExplicitlyRequested() {
        var drawer = ResultsDrawerState()
        drawer.userMoved(to: .tip)
        drawer.searchFinished()
        XCTAssertEqual(drawer.level, .tip)

        drawer.showResults()
        XCTAssertEqual(drawer.level, .medium)
    }

    func testEmptyPlaceQueryUsesDoneWhileTextUsesSearch() {
        XCTAssertEqual(PlaceSearchSubmission.action(for: "   "), .dismissKeyboard)
        XCTAssertEqual(PlaceSearchSubmission.action(for: "Paris"), .showCandidates)
    }

    func testRegionalCapitalFallbackUsesPhoneRegionCode() throws {
        let china = try XCTUnwrap(RegionalCapitalResolver.capital(forRegionCode: "cn"))
        XCTAssertEqual(china.name, "Beijing")
        XCTAssertEqual(china.latitude, 39.90172, accuracy: 0.001)
        XCTAssertEqual(china.longitude, 116.394201, accuracy: 0.001)

        let france = try XCTUnwrap(RegionalCapitalResolver.capital(forRegionCode: "FR"))
        XCTAssertEqual(france.name, "Paris")
        XCTAssertNil(RegionalCapitalResolver.capital(forRegionCode: nil))
    }

    func testIndexedAdministrativePlaceMatchingRequiresTwoCharactersAndWordPrefix() {
        XCTAssertNil(AdministrativePlaceNameMatcher.rank(query: "p", names: ["Paris"]))
        XCTAssertNil(AdministrativePlaceNameMatcher.rank(query: "n", names: ["France", "Shijiazhuang", "Tianjin", "China"]))
        XCTAssertEqual(AdministrativePlaceNameMatcher.rank(query: "Paris", names: ["Paris"]), 0)
        XCTAssertEqual(AdministrativePlaceNameMatcher.rank(query: "Pa", names: ["Paris"]), 1)
        XCTAssertEqual(AdministrativePlaceNameMatcher.rank(query: "Yo", names: ["New York"]), 2)
        XCTAssertNil(AdministrativePlaceNameMatcher.rank(query: "aris", names: ["Paris"]))
        XCTAssertNil(AdministrativePlaceNameMatcher.rank(query: "Paris", names: ["Beijing"]))
    }

    func testUnifiedSearchMatchesAcrossNamesAndMetadataWithoutGuessingResultType() {
        XCTAssertEqual(
            SearchTextMatcher.rank(query: "喋血街頭", fields: ["Bullet in the Head", #"{"zh":"喋血街頭"}"#]),
            1
        )
        XCTAssertEqual(
            SearchTextMatcher.rank(query: "John Woo", fields: [#"[{"qid":"Q55432","name":"John Woo"}]"#]),
            1
        )
        XCTAssertEqual(
            SearchTextMatcher.rank(query: "Beijing", fields: ["Summer Palace", "北京市 Beijing Q956"]),
            1
        )
        XCTAssertNil(SearchTextMatcher.rank(query: "北", fields: ["北京市"]))
        XCTAssertNil(SearchTextMatcher.rank(query: "Spielberg", fields: ["John Woo", "Beijing"]))
    }

    func testSearchOnlyAcceptsTheLatestEligibleQuery() throws {
        var tracker = SearchRequestTracker()

        let first = try XCTUnwrap(tracker.update("  Be  "))
        let latest = try XCTUnwrap(tracker.update("Beijing"))

        XCTAssertEqual(first, "Be")
        XCTAssertFalse(tracker.accepts(first))
        XCTAssertTrue(tracker.accepts(latest))
    }

    func testShortSearchQueryClearsAndInvalidatesPendingWork() throws {
        var tracker = SearchRequestTracker()
        let pending = try XCTUnwrap(tracker.update("Paris"))

        XCTAssertNil(tracker.update(" p "))
        XCTAssertFalse(tracker.accepts(pending))
    }

    func testUnifiedSearchOrdersAllPlacesBeforeMovies() {
        XCTAssertEqual(
            SearchSuggestionOrder.placesFirst(
                indexedPlaces: ["indexed-place"],
                mapPlaces: ["map-place"],
                movies: ["movie"]
            ),
            ["indexed-place", "map-place", "movie"]
        )
    }

    func testIndependentTimeRangesDoNotFillGaps() {
        let ranges = [
            StoryTimeRange(startYear: 1955, endYear: 1955),
            StoryTimeRange(startYear: 1985, endYear: 1985)
        ]
        XCTAssertTrue(StoryTimeMatcher.matches(year: 1955, ranges: ranges))
        XCTAssertFalse(StoryTimeMatcher.matches(year: 1970, ranges: ranges))
        XCTAssertTrue(StoryTimeMatcher.matches(year: 1985, ranges: ranges))
    }

    func testStoryTimeRangeMatchesAnyOverlappingMoviePeriod() {
        let ranges = [StoryTimeRange(startYear: 1980, endYear: 1989)]

        XCTAssertTrue(StoryTimeMatcher.matches(startYear: 1975, endYear: 1980, ranges: ranges))
        XCTAssertTrue(StoryTimeMatcher.matches(startYear: 1985, endYear: 2000, ranges: ranges))
        XCTAssertFalse(StoryTimeMatcher.matches(startYear: 1990, endYear: 2000, ranges: ranges))
    }

    func testStoryTimeSelectionClampsAndKeepsAnOrderedRange() {
        var selection = StoryTimeSelection(startYear: 1500, endYear: 2200)
        XCTAssertEqual(selection.startYear, 1600)
        XCTAssertEqual(selection.endYear, 2100)

        selection.updateStartYear(2050)
        selection.updateEndYear(2000)
        XCTAssertEqual(selection.startYear, 2000)
        XCTAssertEqual(selection.endYear, 2000)

        selection.updateStartYear(2200)
        XCTAssertEqual(selection.startYear, 2100)
        XCTAssertEqual(selection.endYear, 2100)
    }

    func testUnknownStoryTimeOnlyAppearsForTheCompleteDefaultRange() {
        XCTAssertTrue(StoryTimeAvailabilityMatcher.includesUnknown(startYear: 1600, endYear: 2100))
        XCTAssertFalse(StoryTimeAvailabilityMatcher.includesUnknown(startYear: 1800, endYear: 2100))
        XCTAssertFalse(StoryTimeAvailabilityMatcher.includesUnknown(startYear: 1600, endYear: 2000))
    }

    func testContemporaryNormalizesToReleaseDecade() {
        let range = TimeNormalizer.contemporaryRange(releaseYear: 1994)
        XCTAssertEqual(range.startYear, 1990)
        XCTAssertEqual(range.endYear, 1999)
    }

    func testLanguageFallbackPreferredThenEnglishThenOriginal() {
        let texts = [
            MovieText(languageCode: "en", title: "English", overview: "EN"),
            MovieText(languageCode: "fr", title: "Français", overview: "FR")
        ]
        XCTAssertEqual(LanguageResolver.resolve(texts: texts, preferred: "ja", original: "fr")?.title, "English")
        XCTAssertEqual(LanguageResolver.resolve(texts: texts.filter { $0.languageCode != "en" }, preferred: "ja", original: "fr")?.title, "Français")
        XCTAssertEqual(LanguageResolver.resolve(texts: texts, preferred: "fr", original: "en")?.title, "Français")
    }

    func testInterfaceLanguageUsesExplicitChoiceOrSystemLanguage() {
        XCTAssertEqual(
            InterfaceLanguageResolver.identifier(preference: "zh-Hans", systemLanguages: ["en-US"]),
            "zh-Hans"
        )
        XCTAssertEqual(
            InterfaceLanguageResolver.identifier(preference: "system", systemLanguages: ["zh-Hans-CN"]),
            "zh-Hans"
        )
        XCTAssertEqual(
            InterfaceLanguageResolver.identifier(preference: "system", systemLanguages: ["fr-FR"]),
            "fr"
        )
    }

    func testBayesianRankingRewardsLargeVoteCounts() {
        let smallPerfect = RankingCalculator.bayesian(rating: 9.0, votes: 10, globalMean: 7.0, minimumVotes: 500)
        let largeStrong = RankingCalculator.bayesian(rating: 8.2, votes: 100_000, globalMean: 7.0, minimumVotes: 500)
        XCTAssertGreaterThan(largeStrong, smallPerfect)
    }

    func testLocationFallbackWalksParentsUntilMoviesExist() {
        let resolver = LocationFallbackResolver(parentByID: ["shijiazhuang":"hebei", "hebei":"china"])
        let resolved = resolver.firstLocationWithResults(start: "shijiazhuang") { id in
            id == "hebei" ? 8 : 0
        }
        XCTAssertEqual(resolved?.locationID, "hebei")
        XCTAssertEqual(resolved?.fallbackDepth, 1)
    }

    func testAdministrativeSearchFallsBackFromCityToRegionToSearchedCountry() {
        let hierarchy = AdministrativeLocationHierarchy(
            locality: "Paris",
            subAdministrativeArea: nil,
            administrativeArea: "Île-de-France",
            country: "France"
        )

        XCTAssertEqual(hierarchy.databaseCandidateNames, ["Paris", "Île-de-France", "France"])
    }

    func testAdministrativeSearchNeverAddsChinaAsAnUnrelatedFallback() {
        let hierarchy = AdministrativeLocationHierarchy(
            locality: "Paris",
            subAdministrativeArea: nil,
            administrativeArea: nil,
            country: "France"
        )

        XCTAssertEqual(hierarchy.databaseCandidateNames, ["Paris", "France"])
        XCTAssertEqual(hierarchy.countryFallbackName, "France")
        XCTAssertFalse(hierarchy.databaseCandidateNames.contains("China"))
    }

    func testAdministrativeSearchExcludesPOIAndNeighborhoodNames() {
        let hierarchy = AdministrativeLocationHierarchy(
            pointOfInterestName: "Hôtel de Ville",
            locality: "Paris",
            subLocality: "Montmartre",
            subAdministrativeArea: nil,
            administrativeArea: "Île-de-France",
            country: "France"
        )

        XCTAssertFalse(hierarchy.databaseCandidateNames.contains("Hôtel de Ville"))
        XCTAssertFalse(hierarchy.databaseCandidateNames.contains("Montmartre"))
    }
    func testTraditionalChineseDoesNotSilentlyUseSimplifiedChinese() {
        let texts = [
            MovieText(languageCode: "zh-Hans", title: "简体", overview: ""),
            MovieText(languageCode: "en", title: "English", overview: "")
        ]
        XCTAssertEqual(LanguageResolver.resolve(texts: texts, preferred: "zh-Hant-TW", original: "zh-Hans")?.title, "English")
    }

    func testHistoricalYearFormatterUsesBCE() {
        XCTAssertEqual(HistoricalYearFormatter.string(44), "44")
        XCTAssertEqual(HistoricalYearFormatter.string(-44), "44 BCE")
        XCTAssertEqual(StoryTimeRange(startYear: -44, endYear: -31).displayText, "44 BCE–31 BCE")
    }

    func testCSVLabelsUsePreferredLanguageThenEnglish() {
        let labels = #"{"en":"The Blue Kite","zh":"蓝风筝","pt-br":"O Papagaio Azul"}"#

        XCTAssertEqual(CSVContentDecoder.localizedLabel(json: labels, preferredLanguage: "zh-Hans-CN"), "蓝风筝")
        XCTAssertEqual(CSVContentDecoder.localizedLabel(json: labels, preferredLanguage: "pt-BR"), "O Papagaio Azul")
        XCTAssertEqual(CSVContentDecoder.localizedLabel(json: labels, preferredLanguage: "zh-Hant-TW"), "The Blue Kite")
        XCTAssertEqual(
            Set(CSVContentDecoder.labelValues(json: labels)),
            Set(["The Blue Kite", "蓝风筝", "O Papagaio Azul"])
        )
    }

    func testCSVNamedEntitiesPreserveQIDsAndNames() {
        let json = #"[{"qid":"Q532645","name":"Tian Zhuangzhuang"}]"#

        XCTAssertEqual(
            CSVContentDecoder.namedEntities(json: json),
            [CSVNamedEntity(qid: "Q532645", name: "Tian Zhuangzhuang")]
        )
    }

    func testWorkerDetailDecodesPosterURLDirectorsAndCast() throws {
        let data = #"{"id":550,"title":"Fight Club","originalTitle":"Fight Club","overview":"Overview","tagline":"Tagline","posterPath":"/poster.jpg","posterUrl":"https://cdn.example/posters/550.jpg","backdropPath":null,"releaseDate":"1999-10-15","runtime":139,"originalLanguage":"en","status":"Released","genres":[{"id":18,"name":"Drama"}],"rating":8.4,"voteCount":10,"popularity":3.0,"directors":[{"id":1,"name":"Director","originalName":"Director","profilePath":null}],"cast":[{"id":2,"name":"Actor","originalName":"Actor","character":"Lead","profilePath":null,"order":0}]}"#.data(using: .utf8)!
        let value = try JSONDecoder().decode(MovieMetadata.self, from: data)

        XCTAssertEqual(value.posterURL?.absoluteString, "https://cdn.example/posters/550.jpg")
        XCTAssertEqual(value.directors.map(\.name), ["Director"])
        XCTAssertEqual(value.cast.map(\.character), ["Lead"])
    }

    func testDetailRequestUsesOnlyWorkerAndFixedEnglish() throws {
        let request = try MovieMetadataRequest.detail(tmdbID: 550).urlRequest

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://reelspan-tmdb.xiaoguiwk.workers.dev/movie/550?language=en-US"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testPosterURLPrefersWorkerThenFallsBackToPath() {
        XCTAssertEqual(
            MovieMetadataImageURLs.poster(primary: "https://cdn.example/550.jpg", path: "/p.jpg")?.absoluteString,
            "https://cdn.example/550.jpg"
        )
        XCTAssertEqual(
            MovieMetadataImageURLs.poster(primary: nil, path: "/p.jpg")?.absoluteString,
            "https://image.tmdb.org/t/p/w342/p.jpg"
        )
        XCTAssertNil(MovieMetadataImageURLs.poster(primary: nil, path: nil))
    }

    func testSearchRequestUsesWorkerEnglishAndEscapesQuery() throws {
        let request = try MovieMetadataRequest.search(query: "Fight Club", page: 2).urlRequest

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://reelspan-tmdb.xiaoguiwk.workers.dev/search/movie?query=Fight%20Club&page=2&language=en-US"
        )
    }

    func testMetadataRequestRejectsInvalidArguments() {
        XCTAssertThrowsError(try MovieMetadataRequest.detail(tmdbID: 0).urlRequest)
        XCTAssertThrowsError(try MovieMetadataRequest.search(query: "  ", page: 1).urlRequest)
        XCTAssertThrowsError(try MovieMetadataRequest.search(query: "Fight Club", page: 0).urlRequest)
    }

    func testImageURLBuildersRejectInsecurePrimaryAndMalformedFallback() {
        XCTAssertEqual(MovieMetadataImageURLs.poster(primary: "http://cdn.example/550.jpg", path: "/p.jpg")?.absoluteString,
                       "https://image.tmdb.org/t/p/w342/p.jpg")
        XCTAssertNil(MovieMetadataImageURLs.poster(primary: nil, path: "p.jpg"))
        XCTAssertEqual(
            MovieMetadataImageURLs.searchPoster(primary: nil, path: "/p.jpg")?.absoluteString,
            "https://image.tmdb.org/t/p/w185/p.jpg"
        )
        XCTAssertEqual(
            MovieMetadataImageURLs.profile(path: "/person.jpg")?.absoluteString,
            "https://image.tmdb.org/t/p/w185/person.jpg"
        )
    }

    func testMovieMetadataCacheExpiresAfterThirtyDays() throws {
        let root = temporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var current = Date(timeIntervalSince1970: 1_000)
        let cache = MovieMetadataCache(root: root, now: { current })

        try cache.writeMetadata(.fixture(id: 550), tmdbID: 550)
        XCTAssertNotNil(try cache.readMetadata(tmdbID: 550))

        current.addTimeInterval(MovieCachePolicy.maximumAge + 1)
        XCTAssertNil(try cache.readMetadata(tmdbID: 550))
    }

    func testMovieMetadataCacheDeletesCorruptEntries() throws {
        let root = temporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MovieMetadataCache(root: root)
        let metadataURL = root.appendingPathComponent("movie-en-US-550.json")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: metadataURL)

        XCTAssertNil(try cache.readMetadata(tmdbID: 550))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    func testMovieMetadataCacheReadRefreshesAccessDateForLRUEviction() throws {
        let root = temporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var current = Date(timeIntervalSince1970: 1_000)
        let cache = MovieMetadataCache(root: root, maximumBytes: 10, now: { current })

        try cache.writeRaw(Data(repeating: 1, count: 4), key: "old")
        current.addTimeInterval(1)
        try cache.writeRaw(Data(repeating: 2, count: 4), key: "recently-read")
        current.addTimeInterval(1)
        XCTAssertEqual(cache.rawData(key: "old")?.count, 4)
        current.addTimeInterval(1)
        try cache.writeRaw(Data(repeating: 3, count: 4), key: "new")

        XCTAssertEqual(cache.rawData(key: "old")?.count, 4)
        XCTAssertNil(cache.rawData(key: "recently-read"))
        XCTAssertEqual(cache.rawData(key: "new")?.count, 4)
    }

    func testMovieMetadataCacheEvictsLeastRecentlyUsedFilesUntilUnderLimit() throws {
        let root = temporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var current = Date(timeIntervalSince1970: 1_000)
        let cache = MovieMetadataCache(root: root, maximumBytes: 10, now: { current })

        try cache.writeRaw(Data(repeating: 1, count: 6), key: "old")
        current.addTimeInterval(1)
        try cache.writeRaw(Data(repeating: 2, count: 6), key: "new")

        XCTAssertNil(cache.rawData(key: "old"))
        XCTAssertEqual(cache.rawData(key: "new")?.count, 6)
    }

    func testMovieMetadataCacheImageKeysIncludeTheResolvedPresentationURL() throws {
        let root = temporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MovieMetadataCache(root: root)
        let compact = try XCTUnwrap(URL(string: "https://image.tmdb.org/t/p/w185/poster.jpg"))
        let large = try XCTUnwrap(URL(string: "https://image.tmdb.org/t/p/w342/poster.jpg"))

        try cache.writeImage(Data([1]), for: compact)
        try cache.writeImage(Data([2]), for: large)

        XCTAssertEqual(cache.cachedImage(for: compact), Data([1]))
        XCTAssertEqual(cache.cachedImage(for: large), Data([2]))
    }

    func testMovieMetadataCachePolicyMatchesRetentionAndBudget() {
        XCTAssertEqual(MovieCachePolicy.maximumAge, 2_592_000)
        XCTAssertEqual(MovieCachePolicy.maximumBytes, 157_286_400)
    }

    func testMovieMetadataCacheClearRemovesMetadataAndImages() throws {
        let root = temporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MovieMetadataCache(root: root)
        let imageURL = try XCTUnwrap(URL(string: "https://image.tmdb.org/t/p/w185/poster.jpg"))

        try cache.writeMetadata(.fixture(id: 550), tmdbID: 550)
        try cache.writeImage(Data([1]), for: imageURL)
        try cache.clear()

        XCTAssertNil(try cache.readMetadata(tmdbID: 550))
        XCTAssertNil(cache.cachedImage(for: imageURL))
    }

    func testMovieMetadataCacheAtomicWriteKeepsOpenReaderOnPriorVersion() throws {
        let root = temporaryCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MovieMetadataCache(root: root)
        let first = MovieMetadata.fixture(id: 550)
        let replacement = MovieMetadata.fixture(id: 550, directors: [.fixture(name: "Replacement")])
        let metadataURL = root.appendingPathComponent("movie-en-US-550.json")

        try cache.writeMetadata(first, tmdbID: 550)
        let firstData = try Data(contentsOf: metadataURL)
        let reader = try FileHandle(forReadingFrom: metadataURL)
        defer { try? reader.close() }

        try cache.writeMetadata(replacement, tmdbID: 550)

        XCTAssertEqual(try reader.readToEnd(), firstData)
        XCTAssertEqual(try cache.readMetadata(tmdbID: 550)?.directors.map(\.name), ["Replacement"])
    }

    private func temporaryCacheRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

}
