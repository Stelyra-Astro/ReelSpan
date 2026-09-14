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
    @Published var iCloudBackupEnabled: Bool

    let imageManager = ImageDownloadManager()
    let iCloudBackup = ICloudBackupManager()
    private var content: ContentRepository?
    private let movieSearchWorker = MovieSearchWorker()
    private var users: UserDatabase?
    private let locationProvider = DeviceLocationProvider()
    private var didResolveInitialLocation = false
    private var cloudBackupTask: Task<Void, Never>?

    init() {
        interfaceLanguagePreference = UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "system"
        iCloudBackupEnabled = UserDefaults.standard.object(forKey: "iCloudBackupEnabled") as? Bool ?? true
        do {
            content = try ContentRepository()
            users = try UserDatabase()
            favoriteIDs = users?.favoriteIDs() ?? []
            databaseVersion = content?.databaseVersion() ?? "Unknown"
            applyRegionalCapitalFallback()
        } catch {
            errorMessage = error.localizedDescription
        }
        imageManager.onCacheChanged = { [weak self] in self?.scheduleICloudBackup() }
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

    var allMoviesForDownloads: [MovieViewData] {
        content?.allMovies(preferredLanguage: effectiveLanguage) ?? []
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
        await iCloudBackup.backup(manifest, localCacheDirectory: imageManager.cacheDirectoryForBackup)
    }

    private func restoreICloudBackup() async {
        guard iCloudBackupEnabled, let content else { return }
        guard let manifest = await iCloudBackup.restore(
            localCacheDirectory: imageManager.cacheDirectoryForBackup
        ) else { return }
        let restoredIDs = content.movieIDs(qids: manifest.favoriteMovieQIDs)
        favoriteIDs = restoredIDs
        users?.replaceFavorites(with: restoredIDs)
        if !manifest.interfaceLanguage.isEmpty {
            interfaceLanguagePreference = manifest.interfaceLanguage
            UserDefaults.standard.set(manifest.interfaceLanguage, forKey: "interfaceLanguage")
        }
        imageManager.refreshCacheSize()
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

    func indexedPlaceSuggestions(_ query: String) -> [MapSearchSuggestion] {
        guard let content else { return [] }
        return content.administrativeLocationMatches(query: query, preferredLanguage: effectiveLanguage).compactMap { location in
            guard let coordinate = location.coordinate else { return nil }
            var names = [location.name]
            var countryName: String? = location.type == "country" ? location.name : nil
            var parentID = location.parentID
            var visited = Set([location.id])
            while let id = parentID, !visited.contains(id), let parent = content.location(id: id, preferredLanguage: effectiveLanguage) {
                visited.insert(id)
                names.append(parent.name)
                if parent.type == "country" { countryName = parent.name }
                parentID = parent.parentID
            }
            let selection = MapSearchSelection(
                displayName: location.name,
                coordinate: coordinate,
                candidateDatabaseNames: names,
                countryFallbackName: countryName
            )
            return MapSearchSuggestion(
                title: location.name,
                subtitle: names.dropFirst().joined(separator: " · "),
                selection: selection
            )
        }
    }

    func movieSuggestions(_ query: String) async -> [MovieViewData] {
        await movieSearchWorker.suggestions(
            query: query,
            preferredLanguage: effectiveLanguage
        )
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
                movies = []
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
            movies = []
            return
        }
        guard !Task.isCancelled else { return }
        selectedLocation = nearest
        displayedPlaceName = nearest.name
        reload()
    }

    func reload() {
        guard let content, let requested = selectedLocation else { return }
        let result = content.search(
            startYear: storyTimeSelection.startYear,
            endYear: storyTimeSelection.endYear,
            requestedLocation: requested,
            preferredLanguage: effectiveLanguage,
            favoritesOnly: favoritesOnly,
            favoriteIDs: favoriteIDs
        )
        movies = result.movies
        if result.didFallback {
            let range = "\(L10n.year(storyTimeSelection.startYear))–\(L10n.year(storyTimeSelection.endYear))"
            fallbackMessage = L10n.format("home.fallback_message", result.requestedLocation.name, range, result.matchedLocation.name)
        } else if fallbackMessage?.contains(result.requestedLocation.name) != true {
            fallbackMessage = nil
        }
    }

    private func applyRegionalCapitalFallback() {
        let regionCode = Locale.current.region?.identifier
        guard let capital = RegionalCapitalResolver.capital(forRegionCode: regionCode) else {
            selectedLocation = nil
            movies = []
            return
        }

        selectedCoordinate = CLLocationCoordinate2D(latitude: capital.latitude, longitude: capital.longitude)
        let countryName = regionCode.flatMap { Locale.current.localizedString(forRegionCode: $0) }
        selectedLocation = content?.bestLocationMatch(
            candidateNames: [capital.name, countryName].compactMap { $0 },
            preferredLanguage: effectiveLanguage
        )
        displayedPlaceName = selectedLocation?.name ?? capital.name
        if selectedLocation != nil { reload() } else { movies = [] }
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
