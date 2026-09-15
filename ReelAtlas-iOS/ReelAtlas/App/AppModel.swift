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
    @Published var favoriteIDs = Set<Int>()
    @Published var favoritesOnly = false
    @Published var fallbackMessage: String?
    @Published var errorMessage: String?
    @Published var interfaceLanguagePreference: String
    @Published var databaseVersion = "Unknown"
    @Published var isSearching = false
    @Published private(set) var isContentLoading = true
    @Published private(set) var isLoadingMovies = false
    @Published private(set) var hasMoreMovies = false
    @Published private(set) var movieCacheBytes: Int64 = 0
    @Published private(set) var initialLocationResolved = false
    @Published var iCloudBackupEnabled: Bool

    let metadataStore = MovieMetadataStore()
    let tipManager = TipPurchaseManager()
    let iCloudBackup = ICloudBackupManager()
    private var content: ContentRepository?
    private let contentSync = StoryContentSyncService()
    private let searchData = SearchDataWorker()
    private let moviePages = MoviePageWorker()
    private var users: UserDatabase?
    private let locationProvider = DeviceLocationProvider()
    private var didResolveInitialLocation = false
    private var pendingInitialCoordinate: CLLocationCoordinate2D?
    private var contentBootstrapGate = ContentBootstrapGate()
    private var cloudBackupTask: Task<Void, Never>?
    private var moviePageTask: Task<Void, Never>?
    private var moviePageGeneration = UUID()
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
        defer { isContentLoading = false }
        do {
            let databaseURL = try await contentSync.ensureCurrentContent()
            let repository = try ContentRepository(databaseURL: databaseURL)
            content = repository
            await searchData.configure(databaseURL: databaseURL)
            await moviePages.configure(databaseURL: databaseURL)
            databaseVersion = repository.databaseVersion()

            if contentBootstrapGate.markContentReady() {
                await resolvePendingInitialLocation()
            } else {
                applyCaliforniaFallback()
            }
            if iCloudBackupEnabled { await restoreICloudBackup() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var effectiveLanguage: String {
        effectiveInterfaceLanguage
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
            applyCaliforniaFallback()
            return
        }
        pendingInitialCoordinate = nil
        await selectMapCoordinate(coordinate)
        initialLocationResolved = true
    }

    func setStoryStartYear(_ value: Int) {
        storyTimeSelection.updateStartYear(value)
        reload()
    }

    func setStoryEndYear(_ value: Int) {
        storyTimeSelection.updateEndYear(value)
        reload()
    }

    func setStoryTimeRange(startYear: Int, endYear: Int) {
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
        guard iCloudBackupEnabled, let content else { return }
        let manifest = ICloudBackupManifest(
            favoriteMovieQIDs: content.movieQIDs(ids: favoriteIDs),
            interfaceLanguage: interfaceLanguagePreference,
            updatedAt: Date()
        )
        await iCloudBackup.backup(manifest)
    }

    private func restoreICloudBackup() async {
        guard iCloudBackupEnabled, let content else { return }
        guard let manifest = await iCloudBackup.restore() else { return }
        let restoredIDs = content.movieIDs(qids: manifest.favoriteMovieQIDs)
        favoriteIDs = restoredIDs
        users?.replaceFavorites(with: restoredIDs)
        if !manifest.interfaceLanguage.isEmpty {
            let restoredLanguage = InterfaceLanguageResolver.identifier(
                preference: manifest.interfaceLanguage,
                systemLanguages: Locale.preferredLanguages
            )
            interfaceLanguagePreference = restoredLanguage
            UserDefaults.standard.set(restoredLanguage, forKey: "interfaceLanguage")
        }
        reload()
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
        await resolveSelection { try await MapSearchService.resolve(suggestion) }
    }

    func indexedPlaceSuggestions(_ query: String) async -> [MapSearchSuggestion] {
        await searchData.places(query: query, language: effectiveLanguage).map { value in
            MapSearchSuggestion(title: value.name, subtitle: value.names.dropFirst().joined(separator: " · "), selection:
                MapSearchSelection(displayName: value.name,
                    coordinate: CLLocationCoordinate2D(latitude: value.latitude, longitude: value.longitude),
                    candidateDatabaseNames: value.names, countryFallbackName: value.country))
        }
    }

    func searchMovies(_ items: [MovieSearchItem]) async -> [MovieViewData] {
        await searchData.movies(items, language: effectiveLanguage)
    }

    func selectMapCoordinate(_ coordinate: CLLocationCoordinate2D, reportErrors: Bool = true) async {
        guard content != nil else { return }
        await resolveSelection(reportErrors: reportErrors, fallbackCoordinate: coordinate) {
            try await MapSearchService.reverseLookup(
                coordinate,
                preferredLocale: Locale(identifier: effectiveInterfaceLanguage)
            )
        }
    }

    private func resolveSelection(
        reportErrors: Bool = true,
        fallbackCoordinate: CLLocationCoordinate2D? = nil,
        _ operation: () async throws -> MapSearchSelection
    ) async {
        isSearching = true
        defer { isSearching = false }
        do {
            let selection = try await operation()
            guard !Task.isCancelled else { return }
            selectedCoordinate = selection.coordinate
            displayedPlaceName = selection.displayName
            if let matched = content?.bestLocationMatch(candidateNames: selection.candidateDatabaseNames, preferredLanguage: effectiveLanguage) {
                selectedLocation = matched
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
        guard let nearest = content?.nearestMovieLocation(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            preferredLanguage: effectiveLanguage
        ) else {
            selectedLocation = nil
            displayedPlaceName = String(format: "%.3f, %.3f", coordinate.latitude, coordinate.longitude)
            clearMovies()
            return
        }
        guard !Task.isCancelled else { return }
        selectedLocation = nearest
        displayedPlaceName = nearest.name
        reload()
    }

    func reload() {
        clearMovies()
        hasMoreMovies = selectedLocation != nil
        loadMoreMovies()
    }

    private func clearMovies() {
        moviePageTask?.cancel()
        moviePageGeneration = UUID()
        movies = []
        isLoadingMovies = false
        hasMoreMovies = false
    }

    func loadMoreMovies() {
        guard !isLoadingMovies, hasMoreMovies, let requested = selectedLocation else { return }
        isLoadingMovies = true
        let generation = moviePageGeneration
        let offset = movies.count
        let startYear = storyTimeSelection.startYear
        let endYear = storyTimeSelection.endYear
        let language = effectiveLanguage
        let favoritesOnly = favoritesOnly
        let favoriteIDs = favoriteIDs
        let targetQID = requested.targetQID
        moviePageTask = Task { [weak self] in
            guard let self else { return }
            let page = await moviePages.page(
                startYear: startYear,
                endYear: endYear,
                targetQID: targetQID,
                language: language,
                favoritesOnly: favoritesOnly,
                favoriteIDs: favoriteIDs,
                offset: offset,
                metadataService: metadataStore.service
            )
            guard !Task.isCancelled, moviePageGeneration == generation else { return }
            movies.append(contentsOf: page.movies)
            hasMoreMovies = page.hasMore
            isLoadingMovies = false
        }
    }

    private func applyCaliforniaFallback() {
        selectedCoordinate = InitialLocationFallback.coordinate
        selectedLocation = content?.bestLocationMatch(
            candidateNames: InitialLocationFallback.candidateNames,
            preferredLanguage: effectiveLanguage
        )
        displayedPlaceName = selectedLocation?.name ?? InitialLocationFallback.displayName
        initialLocationResolved = true
        if selectedLocation != nil { reload() } else { clearMovies() }
    }
}

private actor MoviePageWorker {
    private struct QueryKey: Hashable {
        let startYear: Int
        let endYear: Int
        let targetQID: String
        let language: String
        let favoritesOnly: Bool
        let favoriteIDs: [Int]
    }

    private var content: ContentRepository?
    private var currentKey: QueryKey?
    private var rankedMovies: [MovieViewData] = []

    func configure(databaseURL: URL) {
        content = try? ContentRepository(databaseURL: databaseURL)
        currentKey = nil
        rankedMovies = []
    }

    func page(
        startYear: Int,
        endYear: Int,
        targetQID: String,
        language: String,
        favoritesOnly: Bool,
        favoriteIDs: Set<Int>,
        offset: Int,
        metadataService: MovieMetadataService
    ) async -> MoviePage {
        guard !Task.isCancelled, let content else { return .empty }
        let key = QueryKey(
            startYear: startYear, endYear: endYear, targetQID: targetQID, language: language,
            favoritesOnly: favoritesOnly, favoriteIDs: favoriteIDs.sorted()
        )

        if currentKey != key || offset == 0 {
            let candidates = content.candidateMovies(
                startYear: startYear, endYear: endYear, targetQID: targetQID,
                preferredLanguage: language, favoritesOnly: favoritesOnly, favoriteIDs: favoriteIDs
            )
            let tmdbIDs = candidates.compactMap(\.tmdbID)
            let rankings = (try? await metadataService.rankings(tmdbIDs: tmdbIDs)) ?? []
            let rankingByTMDB = Dictionary(uniqueKeysWithValues: rankings.map { ($0.tmdbID, $0) })
            let byLocalID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
            let ordered = MovieRankingPolicy.sortedCandidates(
                candidates.map { MovieRankingCandidate(localID: $0.id, tmdbID: $0.tmdbID) },
                rankings: rankings
            )
            rankedMovies = ordered.compactMap { candidate in
                guard let movie = byLocalID[candidate.localID] else { return nil }
                guard let tmdbID = movie.tmdbID, let ranking = rankingByTMDB[tmdbID] else { return movie }
                return movie.applying(ranking: ranking)
            }
            currentKey = key
        }

        guard offset < rankedMovies.count else { return .empty }
        let end = min(rankedMovies.count, offset + MoviePaginationPolicy.resultPageSize)
        return MoviePage(
            movies: Array(rankedMovies[offset..<end]),
            hasMore: end < rankedMovies.count
        )
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
            return Place(name: location.name, latitude: latitude, longitude: longitude, names: names, country: country)
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
