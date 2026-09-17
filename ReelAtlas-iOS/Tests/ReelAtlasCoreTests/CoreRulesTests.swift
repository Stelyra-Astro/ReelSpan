import XCTest
@testable import ReelAtlasCore

final class CoreRulesTests: XCTestCase {
    func testInitialLocationFallbackUsesCalifornia() {
        XCTAssertEqual(InitialLocationFallback.displayName, "California")
        XCTAssertEqual(InitialLocationFallback.coordinate.latitude, 36.7783, accuracy: 0.0001)
        XCTAssertEqual(InitialLocationFallback.coordinate.longitude, -119.4179, accuracy: 0.0001)
    }

    func testAdministrativePlaceSearchUsesADeviceIndependentGlobalRegion() {
        XCTAssertEqual(AdministrativePlaceSearchPolicy.regionCenterLatitude, 0, accuracy: 0.0001)
        XCTAssertEqual(AdministrativePlaceSearchPolicy.regionCenterLongitude, 0, accuracy: 0.0001)
        XCTAssertEqual(AdministrativePlaceSearchPolicy.latitudeDelta, 180, accuracy: 0.0001)
        XCTAssertEqual(AdministrativePlaceSearchPolicy.longitudeDelta, 360, accuracy: 0.0001)
    }

    func testSupportedInterfaceLanguagesAreEnglishAndSimplifiedChinese() {
        XCTAssertEqual(InterfaceLanguageResolver.supportedIdentifiers, ["en", "zh-Hans"])
        XCTAssertEqual(
            InterfaceLanguageResolver.identifier(preference: "system", systemLanguages: ["zh-CN"]),
            "zh-Hans"
        )
        XCTAssertEqual(
            InterfaceLanguageResolver.identifier(preference: "ja", systemLanguages: ["ja-JP"]),
            "en"
        )
    }

    func testTipProductIDsContainOnlyTheThreeConsumables() {
        XCTAssertEqual(
            TipRules.productIDs,
            [
                "com.xiaoguiwk.ReelSpan.tip.small",
                "com.xiaoguiwk.ReelSpan.tip.medium",
                "com.xiaoguiwk.ReelSpan.tip.large"
            ]
        )
        XCTAssertTrue(TipRules.isTipProductID("com.xiaoguiwk.ReelSpan.tip.small"))
        XCTAssertFalse(TipRules.isTipProductID("com.example.legacy.tip"))
    }

    func testContentBootstrapDefersInitialSelectionUntilContentIsReady() {
        var gate = ContentBootstrapGate()

        XCTAssertFalse(gate.requestInitialSelection())
        XCTAssertTrue(gate.markContentReady())
        XCTAssertFalse(gate.markContentReady())
    }

    func testContentBootstrapScopeDownloadsOnlyPublishedMatchedMovies() throws {
        let scope = try XCTUnwrap(ContentBootstrapScope(movieQIDs: ["Q2", "Q1", "Q2"]))

        XCTAssertEqual(scope.movieQIDs, ["Q1", "Q2"])
        XCTAssertEqual(scope.postgRESTMovieFilter, "in.(Q1,Q2)")
        XCTAssertEqual(
            ContentBootstrapScope.postgRESTFilter(qids: ["Q956", "Q148", "Q956"]),
            "in.(Q148,Q956)"
        )
        XCTAssertNil(ContentBootstrapScope.postgRESTFilter(qids: []))
        XCTAssertNil(ContentBootstrapScope(movieQIDs: []))
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

    func testResultsDrawerHidesForSearchUntilExplicitlyReopened() {
        var drawer = ResultsDrawerState()
        XCTAssertEqual(drawer.level, .hidden)

        drawer.showResults()
        drawer.searchFocused()
        XCTAssertEqual(drawer.level, .hidden)

        drawer.searchFinished()
        XCTAssertEqual(drawer.level, .hidden)

        drawer.showResults()
        XCTAssertEqual(drawer.level, .medium)
    }

    func testResultsDrawerCanExpandToFull() {
        var drawer = ResultsDrawerState()
        drawer.showResults()
        drawer.move(to: .full)
        XCTAssertEqual(drawer.level, .full)
    }

    func testMapNavigationCollapsesDrawerWithoutReopeningItAfterFocusUpdate() {
        var drawer = ResultsDrawerState()
        drawer.mapNavigationStarted()
        XCTAssertEqual(drawer.level, .hidden)

        drawer.mapFocusUpdated()
        XCTAssertEqual(drawer.level, .hidden)
    }

    func testManualDrawerCollapsePersistsUntilResultsAreExplicitlyRequested() {
        var drawer = ResultsDrawerState()
        drawer.userDismissed()
        drawer.searchFinished()
        XCTAssertEqual(drawer.level, .hidden)

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
        var selection = StoryTimeSelection(startYear: -8000, endYear: 4000)
        XCTAssertEqual(selection.startYear, -7000)
        XCTAssertEqual(selection.endYear, 3000)

        selection.updateStartYear(2050)
        selection.updateEndYear(2000)
        XCTAssertEqual(selection.startYear, 2000)
        XCTAssertEqual(selection.endYear, 2000)

        selection.updateStartYear(4000)
        XCTAssertEqual(selection.startYear, 3000)
        XCTAssertEqual(selection.endYear, 3000)
    }

    func testUnknownStoryTimeOnlyAppearsForTheCompleteDefaultRange() {
        XCTAssertTrue(StoryTimeAvailabilityMatcher.includesUnknown(startYear: -7000, endYear: 3000))
        XCTAssertFalse(StoryTimeAvailabilityMatcher.includesUnknown(startYear: 1800, endYear: 3000))
        XCTAssertFalse(StoryTimeAvailabilityMatcher.includesUnknown(startYear: -7000, endYear: 2000))
    }

    func testMovieCachePolicyUsesThirtyDayExpiryAnd150MiBLimit() {
        XCTAssertEqual(MovieCachePolicy.maximumAge, 30 * 24 * 60 * 60)
        XCTAssertEqual(MovieCachePolicy.maximumBytes, 150 * 1_024 * 1_024)
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
            "en"
        )
    }

    func testMovieMetadataImageURLsPreferSupabasePosterAndSecureFallback() {
        let primary = "https://injisguyqfxfwgnbtghe.supabase.co/storage/v1/object/public/posters/603.jpg"
        XCTAssertEqual(MovieMetadataImageURLs.poster(primary: primary, path: "/poster.jpg")?.absoluteString, primary)
        XCTAssertEqual(
            MovieMetadataImageURLs.searchPoster(primary: nil, path: "/poster.jpg")?.absoluteString,
            "https://image.tmdb.org/t/p/w185/poster.jpg"
        )
        XCTAssertNil(MovieMetadataImageURLs.poster(primary: "http://unsafe.example/poster.jpg", path: nil))
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

    func testCountrySearchResultIsValidWithoutALocality() {
        let result = PlaceSearchResult(
            provider: .mapKit,
            providerPlaceID: "country|FR",
            displayName: "France",
            canonicalName: "France",
            category: .country,
            latitude: 46.2276,
            longitude: 2.2137,
            locality: nil,
            administrativeArea: nil,
            countryName: "France",
            countryCode: "FR"
        )

        XCTAssertTrue(result.hasValidCoordinate)
        XCTAssertEqual(result.storyLocationCandidateNames, ["France"])
        XCTAssertEqual(
            result.movieFilterScope,
            .country(countryCode: "FR", candidateNames: ["France"])
        )
    }

    func testCitySearchResultKeepsSpecificPlaceMovieFilter() {
        let result = PlaceSearchResult.fixture(
            provider: .mapKit,
            displayName: "Paris",
            canonicalName: "Paris",
            locality: "Paris",
            administrativeArea: "Île-de-France",
            countryName: "France",
            latitude: 48.8566,
            longitude: 2.3522
        )

        XCTAssertEqual(
            result.movieFilterScope,
            .place(candidateNames: ["Paris", "Île-de-France", "France"])
        )
    }

    func testLondonFallsBackToPhotonWhenMapKitOnlyReturnsWeakChinaMatch() async throws {
        let calls = SearchProviderCallLog()
        let chinaResult = PlaceSearchResult.fixture(
            provider: .mapKit,
            displayName: "伦敦广场",
            canonicalName: "Lundun Plaza",
            locality: "石家庄",
            countryName: "中国",
            latitude: 38.04,
            longitude: 114.51
        )
        let londonResult = PlaceSearchResult.fixture(
            provider: .photon,
            displayName: "London",
            canonicalName: "London",
            locality: "London",
            countryName: "United Kingdom",
            latitude: 51.5072,
            longitude: -0.1276
        )

        let results = try await PlaceSearchPipeline.search(
            query: "London",
            mapKit: { await calls.record(.mapKit); return [chinaResult] },
            photon: { await calls.record(.photon); return [londonResult] },
            geoNames: { await calls.record(.geoNames); return [] }
        )

        XCTAssertEqual(results.map(\.canonicalName), ["London"])
        let recordedCalls = await calls.values
        XCTAssertEqual(recordedCalls, [.mapKit, .photon])
    }

    func testMapKitPOIPrefixIsNotEnoughToBlockGlobalCityFallback() {
        let weakPOI = PlaceSearchResult.fixture(
            provider: .mapKit,
            displayName: "London Plaza",
            canonicalName: "London Plaza",
            category: .poi,
            locality: "Shijiazhuang",
            countryName: "China",
            latitude: 38.04,
            longitude: 114.51
        )
        let exactPOI = PlaceSearchResult.fixture(
            provider: .mapKit,
            displayName: "Times Square",
            canonicalName: "Times Square",
            category: .poi,
            locality: "New York",
            countryName: "United States",
            latitude: 40.758,
            longitude: -73.9855
        )

        XCTAssertFalse(PlaceSearchRelevance.isRelevant(query: "London", result: weakPOI))
        XCTAssertTrue(PlaceSearchRelevance.isRelevant(query: "Times Square", result: exactPOI))
    }

    func testBeijingStopsAfterRelevantMapKitResult() async throws {
        let calls = SearchProviderCallLog()
        let beijing = PlaceSearchResult.fixture(
            provider: .mapKit,
            displayName: "Beijing",
            canonicalName: "Beijing",
            locality: "Beijing",
            countryName: "China",
            latitude: 39.9042,
            longitude: 116.4074
        )

        let results = try await PlaceSearchPipeline.search(
            query: "Beijing",
            mapKit: { await calls.record(.mapKit); return [beijing] },
            photon: { await calls.record(.photon); return [] },
            geoNames: { await calls.record(.geoNames); return [] }
        )

        XCTAssertEqual(results.map(\.canonicalName), ["Beijing"])
        let recordedCalls = await calls.values
        XCTAssertEqual(recordedCalls, [.mapKit])
    }

    func testChineseNewYorkContinuesFromPhotonToLocalizedGeoNamesResult() async throws {
        let calls = SearchProviderCallLog()
        let newYork = PlaceSearchResult.fixture(
            provider: .geoNames,
            providerPlaceID: "5128581",
            displayName: "纽约",
            canonicalName: "New York City",
            locality: "纽约",
            countryName: "美国",
            latitude: 40.7143,
            longitude: -74.006
        )

        let results = try await PlaceSearchPipeline.search(
            query: "纽约",
            mapKit: { await calls.record(.mapKit); return [] },
            photon: { await calls.record(.photon); return [] },
            geoNames: { await calls.record(.geoNames); return [newYork] }
        )

        XCTAssertEqual(results.first?.displayName, "纽约")
        XCTAssertEqual(results.first?.canonicalName, "New York City")
        XCTAssertEqual(results.first?.providerPlaceID, "5128581")
        let recordedCalls = await calls.values
        XCTAssertEqual(recordedCalls, [.mapKit, .photon, .geoNames])
    }

    func testIrrelevantPhotonResultContinuesToGeoNames() async throws {
        let calls = SearchProviderCallLog()
        let irrelevant = PlaceSearchResult.fixture(
            provider: .photon,
            displayName: "New Town",
            canonicalName: "New Town",
            locality: "New Town",
            countryName: "China",
            latitude: 30,
            longitude: 110
        )
        let newYork = PlaceSearchResult.fixture(
            provider: .geoNames,
            displayName: "纽约",
            canonicalName: "New York City",
            locality: "纽约",
            countryName: "美国",
            latitude: 40.7143,
            longitude: -74.006
        )

        let results = try await PlaceSearchPipeline.search(
            query: "纽约",
            mapKit: { await calls.record(.mapKit); return [] },
            photon: { await calls.record(.photon); return [irrelevant] },
            geoNames: { await calls.record(.geoNames); return [newYork] }
        )

        XCTAssertEqual(results.first?.canonicalName, "New York City")
        let recordedCalls = await calls.values
        XCTAssertEqual(recordedCalls, [.mapKit, .photon, .geoNames])
    }

    func testTimesSquareKeepsPOICoordinateButNormalizesStoryLocationToCity() {
        let result = PlaceSearchResult.fixture(
            provider: .photon,
            displayName: "Times Square",
            canonicalName: "Times Square",
            category: .poi,
            locality: "New York",
            administrativeArea: "New York",
            countryName: "United States",
            latitude: 40.758,
            longitude: -73.9855
        )

        XCTAssertEqual(result.latitude, 40.758, accuracy: 0.0001)
        XCTAssertEqual(result.longitude, -73.9855, accuracy: 0.0001)
        XCTAssertEqual(result.storyLocationCandidateNames.first, "New York")
        XCTAssertFalse(result.storyLocationCandidateNames.contains("Times Square"))
        XCTAssertFalse(result.storyLocationCandidateNames.contains("Manhattan"))
    }

    func testPOIWithoutLocalityNeverFallsBackToDistrictOrCountry() {
        let result = PlaceSearchResult.fixture(
            provider: .geoNames,
            displayName: "Example POI",
            canonicalName: "Example POI",
            category: .poi,
            locality: nil,
            administrativeArea: "Example District",
            countryName: "Example Country",
            latitude: 1,
            longitude: 1
        )

        XCTAssertEqual(result.storyLocationCandidateNames, [])
    }

    func testProviderURLsAlwaysIncludeCurrentAppLanguage() throws {
        XCTAssertEqual(
            try XCTUnwrap(PlaceSearchEndpoint.photon(query: "纽约", language: "zh-Hans")).absoluteString,
            "https://photon.komoot.io/api/?q=%E7%BA%BD%E7%BA%A6&limit=10&lang=zh-Hans"
        )
        XCTAssertEqual(
            try XCTUnwrap(PlaceSearchEndpoint.geoNames(query: "France", language: "fr")).absoluteString,
            "https://secure.geonames.org/searchJSON?q=France&maxRows=10&lang=fr&username=Stelyra"
        )
    }

    func testGeoNamesUsesLocalizedNameCanonicalToponymAndStableID() throws {
        let json = #"{"geonames":[{"geonameId":5128581,"name":"纽约","toponymName":"New York City","lat":"40.71427","lng":"-74.00597","countryCode":"US","countryName":"美国","adminName1":"纽约州","fcl":"P","fcode":"PPLA"}]}"#

        let result = try XCTUnwrap(PlaceSearchResponseDecoder.geoNames(Data(json.utf8)).first)

        XCTAssertEqual(result.displayName, "纽约")
        XCTAssertEqual(result.canonicalName, "New York City")
        XCTAssertEqual(result.providerPlaceID, "5128581")
        XCTAssertEqual(result.category, .locality)
        XCTAssertEqual(result.countryCode, "US")
    }

    func testPhotonPOIUsesRealCityAndExtentWithoutDistrictFallback() throws {
        let json = #"{"features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[-73.9855,40.758]},"properties":{"osm_type":"W","osm_id":123,"type":"house","name":"Times Square","city":"New York","district":"Manhattan","state":"New York","country":"United States","countrycode":"US","extent":[-73.987,40.756,-73.983,40.76]}}]}"#

        let result = try XCTUnwrap(PlaceSearchResponseDecoder.photon(Data(json.utf8)).first)

        XCTAssertEqual(result.category, .poi)
        XCTAssertEqual(result.locality, "New York")
        XCTAssertEqual(result.storyLocationCandidateNames.first, "New York")
        XCTAssertEqual(result.bounds, PlaceSearchBounds(south: 40.756, west: -73.987, north: 40.76, east: -73.983))
    }

    func testSearchPresentationOnlyShowsTemporaryMarkerForPOI() {
        XCTAssertFalse(PlaceSearchPresentation.showsTemporaryMarker(for: .country))
        XCTAssertFalse(PlaceSearchPresentation.showsTemporaryMarker(for: .administrativeArea))
        XCTAssertFalse(PlaceSearchPresentation.showsTemporaryMarker(for: .locality))
        XCTAssertTrue(PlaceSearchPresentation.showsTemporaryMarker(for: .poi))
    }

    func testSearchViewportUsesBoundsOrCategoryLevelZoom() {
        let bounded = PlaceSearchViewportPolicy.viewport(
            category: .country,
            latitude: 46.2,
            longitude: 2.2,
            bounds: PlaceSearchBounds(south: 41, west: -5, north: 51, east: 9)
        )
        XCTAssertEqual(bounded.latitudeDelta, 12, accuracy: 0.001)
        XCTAssertEqual(bounded.longitudeDelta, 16.8, accuracy: 0.001)

        let city = PlaceSearchViewportPolicy.viewport(
            category: .locality,
            latitude: 35.6762,
            longitude: 139.6503,
            bounds: nil
        )
        XCTAssertEqual(city.latitudeDelta, 0.45, accuracy: 0.001)
        XCTAssertEqual(city.longitudeDelta, 0.45, accuracy: 0.001)
    }

    func testUserMapNavigationConsumesSearchViewportIntent() {
        var intent = MapViewportIntent()
        let london = PlaceSearchViewport(
            centerLatitude: 51.5072,
            centerLongitude: -0.1276,
            latitudeDelta: 0.45,
            longitudeDelta: 0.45
        )

        intent.select(london)
        XCTAssertEqual(intent.viewport, london)

        intent.userNavigationStarted()
        XCTAssertNil(intent.viewport)
    }

    func testMapFocusResolutionDoesNotCreateCameraIntentAfterUserNavigation() {
        var intent = MapViewportIntent()
        let london = PlaceSearchViewport(
            centerLatitude: 51.5072,
            centerLongitude: -0.1276,
            latitudeDelta: 0.45,
            longitudeDelta: 0.45
        )
        let paris = PlaceSearchViewport(
            centerLatitude: 48.8566,
            centerLongitude: 2.3522,
            latitudeDelta: 0.45,
            longitudeDelta: 0.45
        )

        intent.selectionResolved(london, source: .searchResult)
        XCTAssertEqual(intent.viewport, london)
        intent.userNavigationStarted()
        intent.selectionResolved(paris, source: .mapNavigation)

        XCTAssertNil(intent.viewport)
    }

    func testSameNamedCityCandidateShowsAdministrativeParentAndCountry() {
        let london = PlaceSearchResult.fixture(
            provider: .mapKit,
            displayName: "London",
            canonicalName: "London",
            locality: "London",
            administrativeArea: "Ontario",
            countryName: "Canada",
            latitude: 42.9849,
            longitude: -81.2453
        )

        XCTAssertEqual(london.parentDisplayNames, ["Ontario", "Canada"])
    }

    func testPhotonCandidateUsesCountyWhenStateIsMissing() throws {
        let json = #"{"features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[-0.1276,51.5072]},"properties":{"osm_type":"R","osm_id":65606,"type":"city","name":"London","county":"Greater London","country":"United Kingdom","countrycode":"GB"}}]}"#

        let london = try XCTUnwrap(PlaceSearchResponseDecoder.photon(Data(json.utf8)).first)

        XCTAssertEqual(london.parentDisplayNames, ["Greater London", "United Kingdom"])
    }

    func testRepresentativeCountryAndCityQueriesAreRelevant() {
        let cases = [
            ("中国", "中国", "China"), ("China", "China", "China"),
            ("法国", "法国", "France"), ("France", "France", "France"),
            ("纽约", "纽约", "New York"), ("New York", "New York", "New York"),
            ("伦敦", "伦敦", "London"), ("London", "London", "London"),
            ("东京", "东京", "Tokyo"), ("Tokyo", "Tokyo", "Tokyo"),
            ("北京", "北京", "Beijing"), ("Beijing", "Beijing", "Beijing"),
            ("Times Square", "Times Square", "Times Square")
        ]
        for (query, display, canonical) in cases {
            let result = PlaceSearchResult.fixture(
                provider: .mapKit,
                displayName: display,
                canonicalName: canonical,
                locality: display,
                countryName: nil,
                latitude: 1,
                longitude: 1
            )
            XCTAssertTrue(PlaceSearchRelevance.isRelevant(query: query, result: result), query)
        }
    }

    func testCountryCodeResolverHandlesSupportedCountryExamples() {
        XCTAssertEqual(CountryCodeResolver.code(candidateNames: ["中国", "China"]), "CN")
        XCTAssertEqual(CountryCodeResolver.code(candidateNames: ["France"]), "FR")
        XCTAssertEqual(CountryCodeResolver.code(candidateNames: ["日本", "Japan"]), "JP")
        XCTAssertEqual(CountryCodeResolver.code(candidateNames: ["美国", "United States"]), "US")
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

}

private actor SearchProviderCallLog {
    private(set) var values: [PlaceSearchProvider] = []
    func record(_ value: PlaceSearchProvider) { values.append(value) }
}

private extension PlaceSearchResult {
    static func fixture(
        provider: PlaceSearchProvider,
        providerPlaceID: String = UUID().uuidString,
        displayName: String,
        canonicalName: String,
        category: PlaceSearchCategory = .locality,
        locality: String?,
        administrativeArea: String? = nil,
        countryName: String?,
        latitude: Double,
        longitude: Double
    ) -> PlaceSearchResult {
        PlaceSearchResult(
            provider: provider,
            providerPlaceID: providerPlaceID,
            displayName: displayName,
            canonicalName: canonicalName,
            category: category,
            latitude: latitude,
            longitude: longitude,
            locality: locality,
            administrativeArea: administrativeArea,
            countryName: countryName,
            countryCode: nil
        )
    }
}
