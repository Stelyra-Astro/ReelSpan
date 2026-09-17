import Foundation
import Combine
import MapKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var storyTimeSelection = StoryTimeSelection()
    @Published var selectedLocation: LocationRecord?
    @Published var selectedCoordinate = InitialLocationFallback.coordinate
    @Published var displayedPlaceName = InitialLocationFallback.displayName
    @Published var movies: [MovieViewData] = []
    @Published private(set) var storyLocationPins: [StoryLocation] = []
    @Published private var mapViewportIntent = MapViewportIntent()
    @Published private(set) var temporarySearchMarker: SearchSelectionMarker?
    @Published var favoriteIDs = Set<Int>()
    @Published var favoritesOnly = false
    @Published var fallbackMessage: String?
    @Published var errorMessage: String?
    @Published var interfaceLanguagePreference: String
    @Published var databaseVersion = "Unknown"
    @Published var isSearching = false
    @Published private(set) var isContentLoading = true
    @Published private(set) var syncDownloaded = 0
    @Published private(set) var syncTotal = 0
    @Published private(set) var syncComplete = false
    @Published private(set) var contentSyncError: String?
    @Published private(set) var isUpdatingContent = false
    @Published var isListMode = false
    @Published private(set) var whenConcepts: [TimeConcept] = []
    @Published private(set) var whereCatalog: [ModernWherePlace] = []
    @Published private(set) var isLoadingWhereCatalog = false
    @Published private(set) var whereCatalogError: String?
    @Published private(set) var movieCountryQIDs: [String: [String]] = [:]
    @Published private(set) var preferredCountryQID = "Q30"
    @Published private(set) var selectedWhen: TimeConcept?
    @Published private(set) var selectedWhere: ModernWherePlace?
    @Published private(set) var globalSearch = ""
    @Published private(set) var selectedGenre: String?
    @Published private(set) var selectedSort = "recommended"
    @Published private(set) var catalogSearchError: String?
    @Published private(set) var isLoadingMovies = false
    @Published private(set) var isRetryingFilms = false
    @Published private(set) var hasMoreMovies = false
    @Published private(set) var mapResultCount: Int?
    @Published private(set) var showingOfflineSamples = false
    @Published private(set) var movieCacheBytes: Int64 = 0
    @Published private(set) var initialLocationResolved = false
    @Published var iCloudBackupEnabled: Bool

    let metadataStore = MovieMetadataStore()
    let tipManager = TipPurchaseManager()
    let contributions = ContributionStore()
    let iCloudBackup = ICloudBackupManager()
    private var content: ContentRepository?
    private let contentSync = StoryContentSyncService()
    private let catalog = CatalogDiscoveryService()
    private let searchData = SearchDataWorker()
    private let moviePages = MoviePageWorker()
    private var users: UserDatabase?
    private let locationProvider = DeviceLocationProvider()
    private var didResolveInitialLocation = false
    private var preferredCountryResolved = false
    private var preferredCountryCode: String?
    private var pendingInitialCoordinate: CLLocationCoordinate2D?
    private var contentBootstrapGate = ContentBootstrapGate()
    private var cloudBackupTask: Task<Void, Never>?
    private var moviePageTask: Task<Void, Never>?
    private var mapCountTask: Task<Void, Never>?
    private var moviePageGeneration = UUID()
    private var movieLocationScope: MovieLocationScope?
    private var catalogRetryTask: Task<Void, Never>?
    private var lastCatalogRequest: CatalogDiscoveryService.Request?
    private var contentSyncRetryTask: Task<Void, Never>?
    private var initialContentRetryTask: Task<Void, Never>?
    private var initialContentRetryDelaySeconds = 30
    private var whereCatalogRetryTask: Task<Void, Never>?
    private var countryLinksRetryTask: Task<Void, Never>?
    private var countryLinksRequested = false
    private var contentSyncRetryDelaySeconds = 30
    private var catalogRetryDelaySeconds = 30
    private var appIsActive = true
    private var isLoadingInitialContent = false
    private var lastContentSyncAttempt = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    init() {
        let savedLanguage = UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "system"
        interfaceLanguagePreference = InterfaceLanguageResolver.identifier(
            preference: savedLanguage,
            systemLanguages: Locale.preferredLanguages
        )
        iCloudBackupEnabled = UserDefaults.standard.object(forKey: "iCloudBackupEnabled") as? Bool ?? true
        metadataStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        do {
            users = try UserDatabase()
            favoriteIDs = users?.favoriteIDs() ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
        Task { [weak self] in await self?.loadStoryContent() }
    }

    private func loadStoryContent() async {
        guard !isLoadingInitialContent else { return }
        isLoadingInitialContent = true
        lastContentSyncAttempt = Date()
        isContentLoading = true
        defer { isContentLoading = false; isLoadingInitialContent = false }
        do {
            let databaseURL = try await contentSync.ensureCurrentContent()
            let repository = try ContentRepository(databaseURL: databaseURL)
            content = repository
            initialContentRetryTask?.cancel()
            initialContentRetryTask = nil
            initialContentRetryDelaySeconds = 30
            await searchData.configure(databaseURL: databaseURL)
            await moviePages.configure(databaseURL: databaseURL)
            databaseVersion = repository.databaseVersion()
            if let initial = try? await contentSync.progress() {
                syncDownloaded = initial.downloaded
                syncTotal = initial.total
                syncComplete = initial.isComplete
            }
            // The cached When catalog is ready with the first movie batch. A slow
            // concepts request must not delay showing the initial list.
            whenConcepts = repository.timeConcepts(preferredLanguage: effectiveLanguage)
            Task { [weak self] in await self?.ensureWhereCatalog() }

            // Show the on-device catalog before reverse geocoding or iCloud.
            applyCaliforniaFallback()
            if contentBootstrapGate.markContentReady() {
                Task { [weak self] in await self?.resolvePendingInitialLocation() }
            }
            if iCloudBackupEnabled && syncComplete {
                Task { [weak self] in await self?.restoreICloudBackup() }
            }
            Task { [weak self] in
                guard let self else { return }
                if let online = try? await self.catalog.concepts(language: self.effectiveLanguage) {
                    self.whenConcepts = online
                }
            }
            Task { [weak self] in await self?.resumeContentSync() }
        } catch {
            // A first install without a usable cache must not show technical error alerts.
            NSLog("[ReelSpan] Initial story cache unavailable: %@", String(describing: error))
            catalogSearchError = "Story cache unavailable"
            scheduleInitialContentRetry()
        }
    }

    func resumeContentSync() async {
        guard content != nil, !isUpdatingContent else { return }
        lastContentSyncAttempt = Date()
        isUpdatingContent = true
        contentSyncError = nil
        defer { isUpdatingContent = false }
        await contentSync.synchronizeRemaining { [weak self] progress in
            await self?.acceptSyncedBatch(progress)
        }
        contentSyncError = await contentSync.lastSyncError
        if contentSyncError == nil {
            contentSyncRetryTask?.cancel()
            contentSyncRetryTask = nil
            contentSyncRetryDelaySeconds = 30
        } else {
            scheduleContentSyncRetry()
        }
    }

    /// Foreground refresh is throttled; sync failures are logged, not shown over usable films.
    func retryContentSyncIfNeeded() async {
        if content == nil {
            if Date().timeIntervalSince(lastContentSyncAttempt) >= 30 { await loadStoryContent() }
            return
        }
        if catalogSearchError != nil {
            if movies.isEmpty { reload() }
            else { await retryCatalogSilently() }
        }
        guard !isUpdatingContent, Date().timeIntervalSince(lastContentSyncAttempt) >= 300 else { return }
        await resumeContentSync()
        if whereCatalog.isEmpty { await ensureWhereCatalog() }
    }

    func setAppActive(_ active: Bool) {
        appIsActive = active
        if !active {
            catalogRetryTask?.cancel()
            catalogRetryTask = nil
            contentSyncRetryTask?.cancel()
            contentSyncRetryTask = nil
            initialContentRetryTask?.cancel()
            initialContentRetryTask = nil
            whereCatalogRetryTask?.cancel()
            whereCatalogRetryTask = nil
            countryLinksRetryTask?.cancel()
            countryLinksRetryTask = nil
        } else {
            if content == nil { scheduleInitialContentRetry() }
            else if contentSyncError != nil { scheduleContentSyncRetry() }
            if whereCatalogError != nil { scheduleWhereCatalogRetry() }
            if countryLinksRequested && movies.contains(where: { movieCountryQIDs[$0.movieQID] == nil }) {
                scheduleCountryLinksRetry()
            }
            if catalogSearchError != nil { scheduleCatalogRetry() }
        }
    }

    private func scheduleInitialContentRetry() {
        guard appIsActive, content == nil, initialContentRetryTask == nil else { return }
        let delay = initialContentRetryDelaySeconds
        initialContentRetryDelaySeconds = min(delay * 2, 300)
        initialContentRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.initialContentRetryTask = nil
            guard self.appIsActive, self.content == nil else { return }
            await self.loadStoryContent()
        }
    }

    private func scheduleWhereCatalogRetry() {
        guard appIsActive, whereCatalogRetryTask == nil else { return }
        whereCatalogRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self else { return }
            self.whereCatalogRetryTask = nil
            guard self.appIsActive else { return }
            await self.ensureWhereCatalog()
        }
    }

    private func scheduleCountryLinksRetry() {
        guard appIsActive, countryLinksRetryTask == nil else { return }
        countryLinksRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self else { return }
            self.countryLinksRetryTask = nil
            guard self.appIsActive else { return }
            await self.loadCountryAssociations()
        }
    }

    private func scheduleContentSyncRetry() {
        guard appIsActive, contentSyncRetryTask == nil, content != nil else { return }
        let delay = contentSyncRetryDelaySeconds
        contentSyncRetryDelaySeconds = min(delay * 2, 300)
        contentSyncRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.contentSyncRetryTask = nil
            guard self.appIsActive else { return }
            await self.resumeContentSync()
        }
    }

    private func scheduleCatalogRetry() {
        guard appIsActive, catalogRetryTask == nil else { return }
        let delay = catalogRetryDelaySeconds
        catalogRetryDelaySeconds = min(delay * 2, 300)
        catalogRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.catalogRetryTask = nil
            guard self.appIsActive else { return }
            if !self.movies.isEmpty {
                await self.retryCatalogSilently()
            } else if self.catalogSearchError != nil {
                self.reload()
            }
        }
    }

    /// Explicit retry bypasses backoff without clearing last-known-good rows.
    func retryUnavailableFilms() async {
        guard !isLoadingMovies, !isContentLoading, !isRetryingFilms else { return }
        isRetryingFilms = true
        defer { isRetryingFilms = false }
        initialContentRetryTask?.cancel()
        initialContentRetryTask = nil
        catalogRetryTask?.cancel()
        catalogRetryTask = nil
        if content == nil {
            await loadStoryContent()
        } else if lastCatalogRequest != nil {
            await catalog.resetRetryCooldown()
            await retryCatalogSilently()
        } else {
            reload()
        }
    }

    /// Refresh the first visible page in place. A failed request must not blank cached rows.
    private func retryCatalogSilently() async {
        guard let request = lastCatalogRequest else {
            if catalogSearchError != nil { reload() }
            return
        }
        guard !isLoadingMovies else {
            scheduleCatalogRetry()
            return
        }
        let generation = moviePageGeneration
        let language = effectiveLanguage
        do {
            let page = try await catalog.page(request, language: language, refresh: true)
            guard moviePageGeneration == generation, appIsActive else { return }
            if page.isStale {
                scheduleCatalogRetry()
                return
            }
            let firstPageCount = min(request.limit, movies.count)
            let sameFirstPage = movies.prefix(firstPageCount).map(\.movieQID) == page.movies.prefix(firstPageCount).map(\.movieQID)
            if sameFirstPage && page.movies.count == firstPageCount {
                hasMoreMovies = MoviePaginationPolicy.hasMoreAfterFirstPageRefresh(
                    loadedCount: movies.count, pageSize: request.limit,
                    currentHasMore: hasMoreMovies, refreshedHasMore: page.hasMore)
                movies.replaceSubrange(0..<firstPageCount, with: page.movies)
            } else {
                movies = page.movies
                hasMoreMovies = page.hasMore
            }
            if !isListMode {
                var seen = Set<String>()
                storyLocationPins = movies.flatMap(\.locations).filter {
                    $0.coordinate != nil && seen.insert($0.rawPlaceQID).inserted
                }
            }
            catalogSearchError = nil
            showingOfflineSamples = false
            catalogRetryDelaySeconds = 30
        } catch {
            guard moviePageGeneration == generation, appIsActive else { return }
            catalogSearchError = "Full catalog search is temporarily unavailable."
            NSLog("[ReelSpan] Silent catalog refresh failed: %@", String(describing: error))
            scheduleCatalogRetry()
        }
    }

    private func acceptSyncedBatch(_ progress: StoryContentSyncService.SyncProgress) async {
        syncDownloaded = progress.downloaded
        syncTotal = progress.total
        syncComplete = progress.isComplete
        guard let url = try? ContentRepository.cacheURL(),
              let refreshed = try? ContentRepository(databaseURL: url) else { return }
        content = refreshed
        databaseVersion = refreshed.databaseVersion()
        await searchData.configure(databaseURL: url)
        await moviePages.configure(databaseURL: url)
        // Counts come from the updated permanent SQLite, independently of network pages.
        refreshMapResultCount()
        // Reconcile changed story locations without interrupting the list's visible film rows.
        // A content batch can arrive repeatedly. Keep the current rows and pins
        // until a matching catalog refresh has actually succeeded.
        if !isListMode && !movies.isEmpty { await retryCatalogSilently() }
        if progress.isComplete && iCloudBackupEnabled {
            await restoreICloudBackup()
            scheduleICloudBackup()
        }
    }

    func setListMode(_ enabled: Bool) {
        guard isListMode != enabled else { return }
        isListMode = enabled
        reload()
    }

    func setGlobalSearch(_ value: String) {
        guard globalSearch != value else { return }
        globalSearch = String(value.prefix(80))
        reload()
    }

    func setWhenConcept(_ concept: TimeConcept?) {
        selectedWhen = concept
        if let start = concept?.startYear, let end = concept?.endYear {
            storyTimeSelection = StoryTimeSelection(startYear: start, endYear: end)
        } else {
            storyTimeSelection = StoryTimeSelection()
        }
        reload()
    }

    func setWherePlace(_ place: ModernWherePlace?) {
        selectedWhere = place
        if !isListMode, let place {
            let matched = place.category == "country"
                ? content?.bestCountryMatch(candidateNames: [place.name, place.englishName], preferredLanguage: effectiveLanguage)
                : content?.bestLocationMatch(candidateNames: [place.name, place.englishName], preferredLanguage: effectiveLanguage)
            if let coordinate = matched?.coordinate {
                selectedCoordinate = coordinate
                displayedPlaceName = place.name
                mapViewportIntent.select(PlaceSearchViewportPolicy.viewport(
                    category: place.category == "country" ? .country : .locality,
                    latitude: coordinate.latitude, longitude: coordinate.longitude, bounds: nil))
            }
        }
        reload()
    }

    func setGenre(_ value: String?) {
        selectedGenre = value
        reload()
    }

    func setSort(_ value: String) {
        selectedSort = value
        reload()
    }

    func ensureWhereCatalog() async {
        // The local snapshot is usable even if Supabase times out. Do not start
        // multiple simultaneous full catalog requests when list/group/Where open.
        let cached = await catalog.cachedWhereCatalog(language: effectiveLanguage)
        if !cached.isEmpty { whereCatalog = cached; refreshPreferredCountry() }
        guard !isLoadingWhereCatalog else { return }
        isLoadingWhereCatalog = true
        defer { isLoadingWhereCatalog = false }
        do {
            let updated = try await catalog.refreshWhereCatalog(language: effectiveLanguage)
            if !updated.isEmpty {
                whereCatalog = updated
                refreshPreferredCountry()
                whereCatalogError = nil
            }
        } catch {
            whereCatalogError = whereCatalog.isEmpty ? error.localizedDescription : nil
            if whereCatalog.isEmpty { scheduleWhereCatalogRetry() }
        }
    }

    private func resolvePreferredCountry(code: String?) {
        guard !preferredCountryResolved else { return }
        preferredCountryResolved = true
        preferredCountryCode = code?.uppercased()
        refreshPreferredCountry()
    }

    private func refreshPreferredCountry() {
        guard let code = preferredCountryCode, !code.isEmpty else {
            preferredCountryQID = "Q30" // No permission, no fix or reverse geocode failure.
            return
        }
        let englishName = Locale(identifier: "en_US").localizedString(forRegionCode: code) ?? ""
        let knownAliases: [String: String] = ["US": "United States", "CN": "People's Republic of China",
                                              "GB": "United Kingdom", "KR": "South Korea", "KP": "North Korea",
                                              "CZ": "Czech Republic", "TR": "Turkey"]
        let name = knownAliases[code] ?? englishName
        if let matching = whereCatalog.first(where: {
            $0.category == "country" && $0.englishName.caseInsensitiveCompare(name) == .orderedSame
        }) {
            if preferredCountryQID != matching.qid {
                preferredCountryQID = matching.qid
                if isListMode && selectedSort == "recommended" && selectedWhere == nil { reload() }
            }
        }
    }

    func loadCountryAssociations() async {
        countryLinksRequested = true
        let missing = movies.map(\.movieQID).filter { movieCountryQIDs[$0] == nil }
        guard !missing.isEmpty else { return }
        for offset in stride(from: 0, to: missing.count, by: 30) {
            let qids = Array(missing.dropFirst(offset).prefix(30))
            guard let found = try? await catalog.movieCountryLinks(movieQIDs: qids) else {
                scheduleCountryLinksRetry()
                return
            }
            for qid in qids { movieCountryQIDs[qid] = found[qid] ?? [] }
        }
        countryLinksRetryTask?.cancel()
        countryLinksRetryTask = nil
    }

    func findModernPlaces(_ query: String) async -> [ModernWherePlace] {
        await ensureWhereCatalog()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return whereCatalog }
        return whereCatalog.filter { $0.name.localizedCaseInsensitiveContains(trimmed) ||
            $0.englishName.localizedCaseInsensitiveContains(trimmed) }
    }

    var effectiveLanguage: String {
        effectiveInterfaceLanguage
    }

    var searchViewport: PlaceSearchViewport? {
        mapViewportIntent.viewport
    }

    func userDidNavigateMap() {
        guard mapViewportIntent.viewport != nil else { return }
        mapViewportIntent.userNavigationStarted()
    }

    var effectiveInterfaceLanguage: String {
        InterfaceLanguageResolver.identifier(
            preference: interfaceLanguagePreference,
            systemLanguages: Locale.preferredLanguages
        )
    }

    var favoriteMovies: [MovieViewData] {
        content?.movies(ids: favoriteIDs, preferredLanguage: effectiveLanguage) ?? []
    }

    func resolveInitialLocation() async {
        guard !didResolveInitialLocation else { return }
        didResolveInitialLocation = true
        pendingInitialCoordinate = await locationProvider.currentCoordinate()
        if contentBootstrapGate.requestInitialSelection() {
            await resolvePendingInitialLocation()
        }
    }

    private func resolvePendingInitialLocation() async {
        guard let coordinate = pendingInitialCoordinate else {
            resolvePreferredCountry(code: nil)
            applyCaliforniaFallback()
            return
        }
        pendingInitialCoordinate = nil
        await selectMapCoordinate(coordinate)
        initialLocationResolved = true
    }

    func setStoryStartYear(_ value: Int) {
        selectedWhen = nil
        storyTimeSelection.updateStartYear(value)
        reload()
    }

    func setStoryEndYear(_ value: Int) {
        selectedWhen = nil
        storyTimeSelection.updateEndYear(value)
        reload()
    }

    func setStoryTimeRange(startYear: Int, endYear: Int) {
        selectedWhen = nil
        storyTimeSelection = StoryTimeSelection(startYear: startYear, endYear: endYear)
        reload()
    }

    func setInterfaceLanguagePreference(_ value: String) {
        interfaceLanguagePreference = value
        UserDefaults.standard.set(value, forKey: "interfaceLanguage")
        if let current = selectedLocation {
            selectedLocation = content?.location(id: current.id, preferredLanguage: effectiveLanguage) ?? current
            displayedPlaceName = selectedLocation?.name ?? displayedPlaceName
        }
        reload()
        scheduleICloudBackup()
    }

    func setFavoritesOnly(_ value: Bool) {
        favoritesOnly = value
        reload()
    }

    func toggleFavorite(_ movieID: Int) {
        guard movieID > 0 else { return }
        let next = !favoriteIDs.contains(movieID)
        users?.setFavorite(movieID: movieID, isFavorite: next)
        if next { favoriteIDs.insert(movieID) } else { favoriteIDs.remove(movieID) }
        if favoritesOnly { reload() }
        scheduleICloudBackup()
    }

    func refreshMovieCacheSize() {
        Task { [weak self] in
            guard let self else { return }
            let bytes = await metadataStore.service.cacheBytes()
            movieCacheBytes = bytes
        }
    }

    func clearMovieCache() async {
        try? await metadataStore.service.clearCache()
        metadataStore.resetLoadedMetadata()
        movieCacheBytes = 0
    }

    func setICloudBackupEnabled(_ enabled: Bool) {
        iCloudBackupEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "iCloudBackupEnabled")
        cloudBackupTask?.cancel()
        if enabled { Task { await restoreICloudBackup() } }
    }

    func syncICloudNow() async {
        guard iCloudBackupEnabled, syncComplete, let content else { return }
        let manifest = ICloudBackupManifest(
            favoriteMovieQIDs: content.movieQIDs(ids: favoriteIDs),
            interfaceLanguage: interfaceLanguagePreference,
            updatedAt: Date()
        )
        await iCloudBackup.backup(manifest)
    }

    private func restoreICloudBackup() async {
        guard iCloudBackupEnabled, syncComplete, let content else { return }
        guard let manifest = await iCloudBackup.restore() else { return }
        let restoredIDs = content.movieIDs(qids: manifest.favoriteMovieQIDs)
        let merged = favoriteIDs.union(restoredIDs)
        let favoritesChanged = merged != favoriteIDs
        if favoritesChanged {
            favoriteIDs = merged
            users?.replaceFavorites(with: merged)
        }
        var languageChanged = false
        if !manifest.interfaceLanguage.isEmpty {
            let restoredLanguage = InterfaceLanguageResolver.identifier(
                preference: manifest.interfaceLanguage,
                systemLanguages: Locale.preferredLanguages
            )
            if restoredLanguage != interfaceLanguagePreference {
                interfaceLanguagePreference = restoredLanguage
                UserDefaults.standard.set(restoredLanguage, forKey: "interfaceLanguage")
                languageChanged = true
            }
        }
        if languageChanged || (favoritesOnly && favoritesChanged) { reload() }
    }

    private func scheduleICloudBackup() {
        guard iCloudBackupEnabled else { return }
        cloudBackupTask?.cancel()
        cloudBackupTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            await self?.syncICloudNow()
        }
    }

    func selectSearchSuggestion(_ suggestion: MapSearchSuggestion) async {
        await resolveSelection(source: .searchResult) { try await MapSearchService.resolve(suggestion) }
    }

    func indexedPlaceSuggestions(_ query: String) async -> [MapSearchSuggestion] {
        await searchData.places(query: query, language: effectiveLanguage).map { value in
            MapSearchSuggestion(title: value.name, subtitle: value.names.dropFirst().joined(separator: " · "), selection:
                MapSearchSelection(displayName: value.name,
                    coordinate: CLLocationCoordinate2D(latitude: value.latitude, longitude: value.longitude),
                    candidateDatabaseNames: value.names, countryFallbackName: value.country,
                    category: value.category, countryCode: value.countryCode,
                    localityName: value.category == .locality ? value.name : nil))
        }
    }

    func searchMovies(_ items: [MovieSearchItem]) async -> [MovieViewData] {
        await searchData.movies(items, language: effectiveLanguage)
    }

    /// Full-catalog suggestions; do not filter by the incomplete local movie cache.
    func unifiedSuggestions(_ query: String) async -> [MovieViewData] {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return [] }
        let request = CatalogDiscoveryService.Request(query: query, limit: 10)
        return (try? await catalog.page(request, language: effectiveLanguage).movies) ?? []
    }

    func selectMapCoordinate(_ coordinate: CLLocationCoordinate2D, reportErrors: Bool = true) async {
        guard content != nil else { return }
        await resolveSelection(
            source: .mapNavigation,
            reportErrors: reportErrors,
            fallbackCoordinate: coordinate
        ) {
            try await MapSearchService.reverseLookup(
                coordinate,
                preferredLocale: Locale(identifier: effectiveInterfaceLanguage)
            )
        }
    }

    private func resolveSelection(
        source: MapSelectionSource,
        reportErrors: Bool = true,
        fallbackCoordinate: CLLocationCoordinate2D? = nil,
        _ operation: () async throws -> MapSearchSelection
    ) async {
        isSearching = true
        defer { isSearching = false }
        do {
            let selection = try await operation()
            guard !Task.isCancelled else { return }
            if didResolveInitialLocation && !preferredCountryResolved {
                resolvePreferredCountry(code: selection.countryCode)
            }
            selectedCoordinate = selection.coordinate
            displayedPlaceName = selection.displayName
            mapViewportIntent.selectionResolved(selection.viewport, source: source)
            temporarySearchMarker = selection.showsTemporaryMarker
                ? SearchSelectionMarker(name: selection.displayName, coordinate: selection.coordinate)
                : nil
            let matched: LocationRecord?
            if selection.category == .country {
                matched = content?.bestCountryMatch(
                    candidateNames: selection.candidateDatabaseNames,
                    preferredLanguage: effectiveLanguage
                )
            } else {
                matched = content?.bestLocationMatch(
                    candidateNames: selection.candidateDatabaseNames,
                    preferredLanguage: effectiveLanguage
                )
            }
            if let matched {
                selectedLocation = matched
                if selection.category == .country {
                    let countryCode = selection.countryCode
                        ?? CountryCodeResolver.code(candidateNames: selection.candidateDatabaseNames)
                        ?? ""
                    movieLocationScope = .country(countryCode: countryCode, countryQID: matched.targetQID)
                } else {
                    movieLocationScope = .place(targetQID: matched.targetQID)
                }
                if matched.name.caseInsensitiveCompare(selection.displayName) != .orderedSame,
                   !selection.displayName.localizedCaseInsensitiveContains(matched.name) {
                    fallbackMessage = L10n.format("home.map_parent_match", selection.displayName, matched.name)
                }
            } else {
                if let fallbackCoordinate {
                    selectNearestMovieLocation(to: fallbackCoordinate)
                    return
                }
                selectedLocation = nil
                movieLocationScope = nil
                displayedPlaceName = selection.countryFallbackName ?? selection.displayName
                if reportErrors { errorMessage = L10n.text("home.location_not_indexed") }
                clearMovies()
                fallbackMessage = nil
                return
            }
            reload()
        } catch {
            guard !Task.isCancelled else { return }
            if MapLookupErrorPolicy.isNonFatal(error) {
                if let fallbackCoordinate { selectNearestMovieLocation(to: fallbackCoordinate) }
                return
            }
            if reportErrors { errorMessage = error.localizedDescription }
        }
    }

    private func selectNearestMovieLocation(to coordinate: CLLocationCoordinate2D) {
        guard !Task.isCancelled else { return }
        selectedCoordinate = coordinate
        fallbackMessage = nil
        temporarySearchMarker = nil
        guard let nearest = content?.nearestMovieLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            preferredLanguage: effectiveLanguage
        ) else {
            selectedLocation = nil
            movieLocationScope = nil
            displayedPlaceName = String(format: "%.3f, %.3f", coordinate.latitude, coordinate.longitude)
            clearMovies()
            return
        }
        guard !Task.isCancelled else { return }
        selectedLocation = nearest
        movieLocationScope = .place(targetQID: nearest.targetQID)
        displayedPlaceName = nearest.name
        reload()
    }

    func reload() {
        clearMovies()
        refreshMapResultCount()
        hasMoreMovies = isListMode || movieLocationScope != nil
        // A selected Where filter is valid even before a map pin has been selected.
        if !isListMode && selectedWhere != nil { hasMoreMovies = true }
        loadMoreMovies()
    }

    private func clearMovies() {
        mapCountTask?.cancel()
        mapCountTask = nil
        mapResultCount = nil
        moviePageTask?.cancel()
        moviePageGeneration = UUID()
        movies = []
        storyLocationPins = []
        lastCatalogRequest = nil
        isLoadingMovies = false
        hasMoreMovies = false
        showingOfflineSamples = false
    }

    /// Count the *complete saved* story dataset; a first loaded page is never a total.
    /// Text/genre/period-QID filters are not fully indexed in the story cache, so
    /// do not claim an exact count for those filters rather than guess from a page.
    private func refreshMapResultCount() {
        mapCountTask?.cancel()
        mapCountTask = nil
        mapResultCount = nil
        guard !isListMode, content != nil,
              globalSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selectedGenre == nil, selectedWhen == nil else { return }
        let sourceScope: MovieLocationScope?
        if let selectedWhere {
            sourceScope = selectedWhere.category == "country"
                ? .country(countryCode: "", countryQID: selectedWhere.qid)
                : .place(targetQID: selectedWhere.qid)
        } else {
            sourceScope = movieLocationScope
        }
        guard let sourceScope else { return }
        let scope: LocalFilmCountScope
        switch sourceScope {
        case .place(let qid): scope = .place(qid)
        case .country(_, let qid): scope = .country(qid)
        }
        let startYear = storyTimeSelection.startYear
        let endYear = storyTimeSelection.endYear
        let includeUnknown = StoryTimeAvailabilityMatcher.includesUnknown(startYear: startYear, endYear: endYear)
        let selectedFavorites: Set<Int>? = favoritesOnly ? favoriteIDs : nil
        let generation = moviePageGeneration
        mapCountTask = Task { [weak self] in
            let count = await Task.detached(priority: .userInitiated) { () -> Int? in
                guard let url = try? ContentRepository.cacheURL(),
                      let store = try? LocalFilmCountStore(databaseURL: url) else { return nil }
                return try? store.exactCount(startYear: startYear, endYear: endYear,
                                             includeUnknown: includeUnknown, scope: scope,
                                             favoriteIDs: selectedFavorites)
            }.value
            guard !Task.isCancelled, let self, self.moviePageGeneration == generation else { return }
            self.mapResultCount = count
        }
    }

    func loadMoreMovies() {
        guard !isLoadingMovies, hasMoreMovies else { return }
        isLoadingMovies = true
        let generation = moviePageGeneration
        let offset = movies.count
        let startYear = storyTimeSelection.startYear
        let endYear = storyTimeSelection.endYear
        let language = effectiveLanguage
        let favoritesOnly = favoritesOnly
        let favoriteIDs = favoriteIDs
        let mapScope = movieLocationScope
        let listScope: MovieLocationScope? = selectedWhere.map { place in
            place.category == "country"
                ? .country(countryCode: "", countryQID: place.qid)
                : .place(targetQID: place.qid)
        }
        let listMode = isListMode
        let search = globalSearch
        let concept = selectedWhen
        let genre = selectedGenre
        let sort = selectedSort == "recommended" && selectedWhere == nil
            ? "country:\(preferredCountryQID)" : selectedSort
        moviePageTask = Task { [weak self] in
            guard let self else { return }
            if !favoritesOnly {
                let allYears = StoryTimeAvailabilityMatcher.includesUnknown(startYear: startYear, endYear: endYear)
                let request = CatalogDiscoveryService.Request(
                    query: search, startYear: allYears ? nil : startYear,
                    endYear: allYears ? nil : endYear,
                    conceptQID: concept?.qid,
                    placeQID: (listMode ? listScope : (listScope ?? mapScope)).flatMap { scope in
                        if case .place(let qid) = scope { return qid }; return nil
                    },
                    countryQID: (listMode ? listScope : (listScope ?? mapScope)).flatMap { scope in
                        if case .country(_, let qid) = scope { return qid }; return nil
                    },
                    genre: genre, sort: sort, offset: offset,
                    limit: MoviePaginationPolicy.resultPageSize)
                if offset == 0 { lastCatalogRequest = request }
                // An exact page snapshot is authoritative for this filter,
                // language, regional sort and offset. Never wait for the RPC.
                if offset == 0, let saved = try? await catalog.cachedPage(request, language: language),
                   !saved.movies.isEmpty || !saved.hasMore {
                    guard !Task.isCancelled, moviePageGeneration == generation else { return }
                    publishCatalogPage(saved, listMode: listMode)
                    if saved.isStale { Task { [weak self] in await self?.retryCatalogSilently() } }
                    return
                }
                // Upgrade path: Build 11 has story SQLite + MovieMetadata-v1,
                // but has never written a discovery-page snapshot. Use only
                // locally matched, titled films and mark the subset as partial.
                let canUseLocal = offset == 0 && search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && concept == nil && genre == nil && (sort == "recommended" || sort.hasPrefix("country:"))
                if canUseLocal {
                    let offline = await moviePages.offlinePage(
                        startYear: startYear, endYear: endYear,
                        scope: listMode ? listScope : (listScope ?? mapScope),
                        language: language, metadataService: metadataStore.service)
                    guard !Task.isCancelled, moviePageGeneration == generation else { return }
                    if !offline.movies.isEmpty {
                        movies = offline.movies
                        storyLocationPins = listMode ? [] : offline.storyLocations
                        hasMoreMovies = false // This is a saved subset, not the complete catalog.
                        showingOfflineSamples = true
                        catalogSearchError = nil
                        isLoadingMovies = false
                        Task { [weak self] in await self?.retryCatalogSilently() }
                        return
                    }
                }
                do {
                    let page = try await catalog.page(request, language: language)
                    guard !Task.isCancelled, moviePageGeneration == generation else { return }
                    publishCatalogPage(page, listMode: listMode)
                    if page.isStale { Task { [weak self] in await self?.retryCatalogSilently() } }
                    return
                } catch {
                    guard !Task.isCancelled, moviePageGeneration == generation else { return }
                    catalogSearchError = "Full catalog search is temporarily unavailable."
                    NSLog("[ReelSpan] Discovery failed: %@", String(describing: error))
                    scheduleCatalogRetry()
                    // Never pass bare Wikidata QIDs off as film titles, nor
                    // show unrelated results for an unavailable exact filter.
                    hasMoreMovies = false
                    isLoadingMovies = false
                    return
                }
            }
            let page = await moviePages.page(
                startYear: startYear, endYear: endYear,
                scope: listMode ? listScope : mapScope, language: language,
                favoritesOnly: favoritesOnly, favoriteIDs: favoriteIDs,
                offset: offset, metadataService: metadataStore.service)
            guard !Task.isCancelled, moviePageGeneration == generation else { return }
            movies.append(contentsOf: page.movies)
            var seen = Set(storyLocationPins.map(\.rawPlaceQID))
            storyLocationPins.append(contentsOf: page.storyLocations.filter { seen.insert($0.rawPlaceQID).inserted })
            hasMoreMovies = page.hasMore
            isLoadingMovies = false
        }
    }

    private func publishCatalogPage(_ page: CatalogDiscoveryService.Page, listMode: Bool) {
        movies.append(contentsOf: page.movies)
        if !listMode {
            var seen = Set(storyLocationPins.map(\.rawPlaceQID))
            storyLocationPins.append(contentsOf: page.movies.flatMap(\.locations).filter { location in
                location.coordinate != nil && seen.insert(location.rawPlaceQID).inserted
            })
        }
        hasMoreMovies = page.hasMore
        catalogSearchError = page.isStale ? "Cached catalog page needs refresh" : nil
        showingOfflineSamples = false
        isLoadingMovies = false
        if !page.isStale {
            catalogRetryTask?.cancel()
            catalogRetryTask = nil
            catalogRetryDelaySeconds = 30
        }
    }

    private func applyCaliforniaFallback() {
        let california = content?.bestLocationMatch(
            candidateNames: InitialLocationFallback.candidateNames,
            preferredLanguage: effectiveLanguage
        )
        // The first-install SQLite intentionally contains only the first movie
        // batch. Its nearest indexed movie is visible immediately, even when
        // the California target has not been downloaded yet.
        let nearest = content?.nearestMovieLocation(
            latitude: InitialLocationFallback.coordinate.latitude,
            longitude: InitialLocationFallback.coordinate.longitude,
            preferredLanguage: effectiveLanguage
        )
        if !syncComplete {
            selectedLocation = nearest ?? california
        } else {
            selectedLocation = california ?? nearest
        }
        selectedCoordinate = selectedLocation?.coordinate ?? InitialLocationFallback.coordinate
        displayedPlaceName = selectedLocation?.name ?? InitialLocationFallback.displayName
        movieLocationScope = selectedLocation.map { .place(targetQID: $0.targetQID) }
        mapViewportIntent.select(PlaceSearchViewportPolicy.viewport(
            category: .administrativeArea,
            latitude: selectedCoordinate.latitude,
            longitude: selectedCoordinate.longitude,
            bounds: nil
        ))
        temporarySearchMarker = nil
        initialLocationResolved = true
        if selectedLocation != nil || isListMode { reload() } else { clearMovies() }
    }
}

private actor MoviePageWorker {
    private var content: ContentRepository?

    func configure(databaseURL: URL) {
        content = try? ContentRepository(databaseURL: databaseURL)
    }

    /// Only the last-known-good metadata files are enumerated. SQLite enforces
    /// the actual location and time predicates before a movie can be shown.
    func offlinePage(startYear: Int, endYear: Int, scope: MovieLocationScope?,
                     language: String, metadataService: MovieMetadataService) async -> MoviePage {
        guard let content, !Task.isCancelled else { return .empty }
        // Never cap this to the 400 most recently viewed files: an older place
        // may have perfectly valid saved metadata that must still work offline.
        let savedIDs = await metadataService.cachedMetadataIDs(limit: .max)
        var movies: [MovieViewData] = []
        for tmdbID in savedIDs {
            guard !Task.isCancelled else { return .empty }
            guard let base = content.cachedMovie(tmdbID: tmdbID, startYear: startYear,
                                                  endYear: endYear, scope: scope,
                                                  preferredLanguage: language) else { continue }
            // Only decode matching files; keep the SQLite match and title paired.
            guard let detail = await metadataService.cachedMetadata(tmdbIDs: [tmdbID]).first,
                  !detail.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            movies.append(base.enriching(with: detail))
            if movies.count == MoviePaginationPolicy.resultPageSize { break }
        }
        var seen = Set<String>()
        let pins = movies.flatMap(\.locations).filter { $0.coordinate != nil && seen.insert($0.rawPlaceQID).inserted }
        return MoviePage(movies: movies, hasMore: false, storyLocations: pins)
    }

    /// Local favorites and map fallback must not wait for an uncached ranking RPC.
    func page(
        startYear: Int, endYear: Int, scope: MovieLocationScope?,
        language: String, favoritesOnly: Bool, favoriteIDs: Set<Int>,
        offset: Int, metadataService: MovieMetadataService
    ) async -> MoviePage {
        guard !Task.isCancelled, let content else { return .empty }
        let size = MoviePaginationPolicy.resultPageSize
        let candidates = content.candidateMovies(
            startYear: startYear, endYear: endYear, scope: scope,
            preferredLanguage: language, favoritesOnly: favoritesOnly,
            favoriteIDs: favoriteIDs, maximum: offset + size + 1)
        guard offset < candidates.count else { return .empty }
        let selected = Array(candidates.dropFirst(offset).prefix(size))
        let hasMore = candidates.count > offset + size
        let saved = await metadataService.cachedMetadata(tmdbIDs: selected.compactMap(\.tmdbID))
        let byTMDB = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let movies = selected.map { movie in
            guard let tmdbID = movie.tmdbID, let details = byTMDB[tmdbID] else { return movie }
            return movie.enriching(with: details)
        }
        var seen = Set<String>()
        let locations = movies.flatMap(\.locations).filter { location in
            location.coordinate != nil && seen.insert(location.rawPlaceQID).inserted
        }
        return MoviePage(movies: movies, hasMore: hasMore, storyLocations: locations)
    }
}

/// SQLite work stays off the main actor and never runs from a SwiftUI body.
private actor SearchDataWorker {
    private var content: ContentRepository?

    func configure(databaseURL: URL) {
        content = try? ContentRepository(databaseURL: databaseURL)
    }

    struct Place: Sendable {
        let name: String
        let latitude: Double
        let longitude: Double
        let names: [String]
        let country: String?
        let category: PlaceSearchCategory
        let countryCode: String?
    }

    func places(query: String, language: String) -> [Place] {
        guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
              let content else { return [] }
        return content.administrativeLocationMatches(query: query, preferredLanguage: language).compactMap { location in
            guard !Task.isCancelled, let latitude = location.latitude, let longitude = location.longitude else { return nil }
            var names = [location.name]
            var country: String? = location.type == "country" ? location.name : nil
            var parentID = location.parentID
            var visited = Set([location.id])
            while let id = parentID, !visited.contains(id), let parent = content.location(id: id, preferredLanguage: language) {
                visited.insert(id)
                names.append(parent.name)
                if parent.type == "country" { country = parent.name }
                parentID = parent.parentID
            }
            let category: PlaceSearchCategory
            switch location.type.lowercased() {
            case "country": category = .country
            case "admin1", "administrativearea", "administrative_area": category = .administrativeArea
            default: category = .locality
            }
            return Place(
                name: location.name,
                latitude: latitude,
                longitude: longitude,
                names: names,
                country: country,
                category: category,
                countryCode: CountryCodeResolver.code(candidateNames: names)
            )
        }
    }

    func movies(_ items: [MovieSearchItem], language: String) -> [MovieViewData] {
        guard let content else { return [] }
        return items.compactMap { item in
            guard !Task.isCancelled, let local = content.movie(tmdbID: item.id, preferredLanguage: language) else { return nil }
            return MovieViewData.searchResult(item, local: local)
        }
    }
}

@MainActor
private final class DeviceLocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentCoordinate() async -> CLLocationCoordinate2D? {
        guard continuation == nil else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            continueForCurrentAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        continueForCurrentAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(with: locations.last?.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: nil)
    }

    private func continueForCurrentAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(with: nil)
        @unknown default:
            finish(with: nil)
        }
    }

    private func finish(with coordinate: CLLocationCoordinate2D?) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: coordinate)
    }
}
