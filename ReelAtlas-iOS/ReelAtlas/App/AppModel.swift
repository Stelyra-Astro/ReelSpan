import Foundation
import Combine
import MapKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var storyTimeSelection = StoryTimeSelection()
    @Published var selectedLocation: LocationRecord?
    @Published var selectedCoordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @Published var displayedPlaceName = ""
    @Published var movies: [MovieViewData] = []
    @Published var favoriteIDs = Set<Int>()
    @Published var favoritesOnly = false
    @Published var fallbackMessage: String?
    @Published var errorMessage: String?
    @Published var interfaceLanguagePreference: String
    @Published var databaseVersion = "Unknown"
    @Published var isSearching = false
    @Published private(set) var isLoadingMovies = false
    @Published private(set) var hasMoreMovies = false
    @Published var iCloudBackupEnabled: Bool

    let metadataStore = MovieMetadataStore()
    let tipManager = TipPurchaseManager()
    let iCloudBackup = ICloudBackupManager()
    private var content: ContentRepository?
    private let searchData = SearchDataWorker()
    private let moviePages = MoviePageWorker()
    private var users: UserDatabase?
    private let locationProvider = DeviceLocationProvider()
    private var didResolveInitialLocation = false
    private var cloudBackupTask: Task<Void, Never>?
    private var moviePageTask: Task<Void, Never>?
    private var moviePageGeneration = UUID()
    private var cancellables = Set<AnyCancellable>()

    init() {
        interfaceLanguagePreference = UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "system"
        iCloudBackupEnabled = UserDefaults.standard.object(forKey: "iCloudBackupEnabled") as? Bool ?? true
        metadataStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        do {
            content = try ContentRepository()
            users = try UserDatabase()
            favoriteIDs = users?.favoriteIDs() ?? []
            databaseVersion = content?.databaseVersion() ?? "Unknown"
            applyRegionalCapitalFallback()
        } catch {
            errorMessage = error.localizedDescription
        }
        if iCloudBackupEnabled {
            Task { [weak self] in await self?.restoreICloudBackup() }
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
        guard let coordinate = await locationProvider.currentCoordinate() else { return }
        await selectMapCoordinate(coordinate)
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
            interfaceLanguagePreference = manifest.interfaceLanguage
            UserDefaults.standard.set(manifest.interfaceLanguage, forKey: "interfaceLanguage")
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
                offset: offset
            )
            guard !Task.isCancelled, moviePageGeneration == generation else { return }
            movies.append(contentsOf: page.movies)
            hasMoreMovies = page.hasMore
            isLoadingMovies = false
        }
    }

    private func applyRegionalCapitalFallback() {
        let regionCode = Locale.current.region?.identifier
        guard let capital = RegionalCapitalResolver.capital(forRegionCode: regionCode) else {
            selectedLocation = nil
            clearMovies()
            return
        }

        selectedCoordinate = CLLocationCoordinate2D(latitude: capital.latitude, longitude: capital.longitude)
        let countryName = regionCode.flatMap { Locale.current.localizedString(forRegionCode: $0) }
        selectedLocation = content?.bestLocationMatch(
            candidateNames: [capital.name, countryName].compactMap { $0 },
            preferredLanguage: effectiveLanguage
        )
        displayedPlaceName = selectedLocation?.name ?? capital.name
        if selectedLocation != nil { reload() } else { clearMovies() }
    }
}

private actor MoviePageWorker {
    private var content: ContentRepository?

    private func repository() -> ContentRepository? {
        if content == nil { content = try? ContentRepository() }
        return content
    }

    func page(
        startYear: Int,
        endYear: Int,
        targetQID: String,
        language: String,
        favoritesOnly: Bool,
        favoriteIDs: Set<Int>,
        offset: Int
    ) -> MoviePage {
        guard !Task.isCancelled, let content = repository() else { return .empty }
        return content.searchPage(
            startYear: startYear,
            endYear: endYear,
            targetQID: targetQID,
            preferredLanguage: language,
            favoritesOnly: favoritesOnly,
            favoriteIDs: favoriteIDs,
            offset: offset
        )
    }
}

/// SQLite work stays off the main actor and never runs from a SwiftUI body.
private actor SearchDataWorker {
    private var content: ContentRepository?
    private func repository() -> ContentRepository? {
        if content == nil { content = try? ContentRepository() }
        return content
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
              let content = repository() else { return [] }
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
        let content = repository()
        return items.compactMap { item in
            guard !Task.isCancelled else { return nil }
            return MovieViewData.searchResult(item, local: content?.movie(tmdbID: item.id, preferredLanguage: language))
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
