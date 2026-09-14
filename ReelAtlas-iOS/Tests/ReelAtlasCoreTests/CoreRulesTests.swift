import XCTest
@testable import ReelAtlasCore

final class CoreRulesTests: XCTestCase {
    func testPosterAssetURLUsesPublicSupabasePosterPath() {
        XCTAssertEqual(
            PosterAssetURL.url(assetID: 1_269_835)?.absoluteString,
            "https://qvfdtvfgnlpctcykpfgy.supabase.co/storage/v1/object/public/posters/1269835.jpg"
        )
        XCTAssertNil(PosterAssetURL.url(assetID: nil))
    }

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

    func testTMDBDetailsDecodesOverviewCreditsAndArtwork() throws {
        let json = #"{"title":"Localized title","overview":"Remote overview","tagline":"A tagline","release_date":"2001-02-03","runtime":123,"original_language":"zh","vote_average":7.6,"vote_count":45,"poster_path":"/poster.jpg","backdrop_path":"/backdrop.jpg","genres":[{"id":18,"name":"Drama"}],"production_countries":[{"iso_3166_1":"CN","name":"China"}],"credits":{"cast":[{"id":9,"name":"Actor","character":"Lead","order":0,"profile_path":"/actor.jpg"}],"crew":[{"id":10,"name":"Director","job":"Director"}]}}"#.data(using: .utf8)!
        let details = try JSONDecoder().decode(TMDBMovieDetails.self, from: json)

        XCTAssertEqual(details.overview, "Remote overview")
        XCTAssertEqual(details.directors, ["Director"])
        XCTAssertEqual(details.cast.first?.name, "Actor")
        XCTAssertEqual(details.posterURL?.absoluteString, "https://image.tmdb.org/t/p/w185/poster.jpg")
        XCTAssertEqual(details.backdropURL?.absoluteString, "https://image.tmdb.org/t/p/w1280/backdrop.jpg")
        XCTAssertEqual(details.cast.first?.profileURL?.absoluteString, "https://image.tmdb.org/t/p/w185/actor.jpg")
    }

    func testArtworkCachePolicyUsesOneSecondDwellAndThirtyDayExpiry() {
        XCTAssertEqual(ArtworkCachePolicy.rowDwellNanoseconds, 1_000_000_000)
        XCTAssertEqual(ArtworkCachePolicy.maximumAge, 30 * 24 * 60 * 60)
        XCTAssertEqual(ArtworkCachePolicy.posterSize, "w185")
        XCTAssertEqual(ArtworkCachePolicy.maximumBytes, 150 * 1_024 * 1_024)
        XCTAssertEqual(ArtworkCachePolicy.maximumConcurrentVisibleRequests, 2)
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

    func testTMDBImageMetadataBuildsSecureImageURLs() throws {
        let data = #"{"poster_path":"/poster.jpg","backdrop_path":"/backdrop.jpg"}"#.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(TMDBImageMetadata.self, from: data)

        XCTAssertEqual(metadata.posterURL?.absoluteString, "https://image.tmdb.org/t/p/w185/poster.jpg")
        XCTAssertEqual(metadata.backdropURL?.absoluteString, "https://image.tmdb.org/t/p/w1280/backdrop.jpg")
        XCTAssertNil(TMDBImageMetadata(posterPath: nil, backdropPath: nil).posterURL)
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
        XCTAssertNil(MovieMetadataImageURLs.poster(primary: "http://cdn.example/550.jpg", path: "/p.jpg"))
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

    private func temporaryCacheRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

}
