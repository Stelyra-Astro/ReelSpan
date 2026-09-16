import Foundation
import MapKit
import CoreLocation
import Combine

struct MapSearchSuggestion: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    fileprivate let selection: MapSearchSelection

    init(title: String, subtitle: String, selection: MapSearchSelection, id: String? = nil) {
        self.id = id ?? "resolved|\(title)|\(subtitle)"
        self.title = title
        self.subtitle = subtitle
        self.selection = selection
    }

    init(result: PlaceSearchResult) {
        self.init(
            title: result.displayName,
            subtitle: result.parentDisplayNames.joined(separator: " · "),
            selection: MapSearchSelection(result: result),
            id: "\(result.provider.rawValue)|\(result.providerPlaceID)"
        )
    }
}

@MainActor
final class AdministrativePlaceSearch: ObservableObject {
    @Published private(set) var suggestions: [MapSearchSuggestion] = []
    @Published private(set) var isSearching = false

    private var task: Task<Void, Never>?
    private var generation = UUID()

    func update(query: String, language: String) {
        cancel(clearResults: true)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        let request = generation
        isSearching = true
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                let values = try await MapSearchService.suggestions(for: trimmed, language: language)
                try Task.checkCancellation()
                guard let self, generation == request else { return }
                suggestions = values
                isSearching = false
            } catch {
                guard let self, generation == request, !Task.isCancelled else { return }
                suggestions = []
                isSearching = false
            }
        }
    }

    func submit(query: String, language: String) async {
        cancel(clearResults: true)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        let request = generation
        isSearching = true
        do {
            let values = try await MapSearchService.suggestions(for: trimmed, language: language)
            guard generation == request, !Task.isCancelled else { return }
            suggestions = values
            isSearching = false
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            suggestions = []
            isSearching = false
        }
    }

    func clear() {
        cancel(clearResults: true)
    }

    private func cancel(clearResults: Bool) {
        generation = UUID()
        task?.cancel()
        task = nil
        isSearching = false
        if clearResults { suggestions = [] }
    }
}

struct MapSearchSelection {
    let displayName: String
    let coordinate: CLLocationCoordinate2D
    let candidateDatabaseNames: [String]
    let countryFallbackName: String?
    let category: PlaceSearchCategory
    let countryCode: String?
    let bounds: PlaceSearchBounds?
    let localityName: String?

    init(
        displayName: String,
        coordinate: CLLocationCoordinate2D,
        candidateDatabaseNames: [String],
        countryFallbackName: String?,
        category: PlaceSearchCategory = .locality,
        countryCode: String? = nil,
        bounds: PlaceSearchBounds? = nil,
        localityName: String? = nil
    ) {
        self.displayName = displayName
        self.coordinate = coordinate
        self.candidateDatabaseNames = candidateDatabaseNames
        self.countryFallbackName = countryFallbackName
        self.category = category
        self.countryCode = countryCode
        self.bounds = bounds
        self.localityName = localityName
    }

    init(result: PlaceSearchResult) {
        self.init(
            displayName: result.displayName,
            coordinate: CLLocationCoordinate2D(latitude: result.latitude, longitude: result.longitude),
            candidateDatabaseNames: result.storyLocationCandidateNames,
            countryFallbackName: result.countryName,
            category: result.category,
            countryCode: result.countryCode,
            bounds: result.bounds,
            localityName: result.locality
        )
    }

    var viewport: PlaceSearchViewport {
        PlaceSearchViewportPolicy.viewport(
            category: category,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            bounds: bounds
        )
    }

    var showsTemporaryMarker: Bool {
        PlaceSearchPresentation.showsTemporaryMarker(for: category)
    }
}

enum MapSearchService {
    private static let timeout: Duration = .seconds(6)

    static let globalSearchRegion = MKCoordinateRegion(
        center: AdministrativePlaceSearchPolicy.regionCenter,
        span: MKCoordinateSpan(
            latitudeDelta: AdministrativePlaceSearchPolicy.latitudeDelta,
            longitudeDelta: AdministrativePlaceSearchPolicy.longitudeDelta
        )
    )

    static func resolve(_ suggestion: MapSearchSuggestion) async throws -> MapSearchSelection {
        let selection = suggestion.selection
        guard selection.category == .poi, selection.localityName == nil else { return selection }
        guard let reverse = try? await reverseLookup(selection.coordinate),
              reverse.localityName != nil else { throw SearchError.noResults }
        return MapSearchSelection(
            displayName: selection.displayName,
            coordinate: selection.coordinate,
            candidateDatabaseNames: reverse.candidateDatabaseNames,
            countryFallbackName: selection.countryFallbackName ?? reverse.countryFallbackName,
            category: .poi,
            countryCode: selection.countryCode ?? reverse.countryCode,
            bounds: selection.bounds,
            localityName: reverse.localityName
        )
    }

    static func suggestions(for query: String, language: String) async throws -> [MapSearchSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let results = try await PlaceSearchPipeline.search(
            query: trimmed,
            mapKit: { try await mapKit(query: trimmed) },
            photon: { try await photon(query: trimmed, language: language) },
            geoNames: { try await geoNames(query: trimmed, language: language) }
        )
        return results.prefix(10).map(MapSearchSuggestion.init(result:))
    }

    private static func mapKit(query: String) async throws -> [PlaceSearchResult] {
        try await withTimeout {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = [.address, .pointOfInterest]
            request.region = globalSearchRegion
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.prefix(10).compactMap(mapKitResult)
        }
    }

    private static func mapKitResult(_ item: MKMapItem) -> PlaceSearchResult? {
        let placemark = item.placemark
        let itemName = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let category: PlaceSearchCategory
        if item.pointOfInterestCategory != nil {
            category = .poi
        } else if placemark.locality != nil {
            let administrativeNames = [placemark.locality, placemark.administrativeArea, placemark.country]
                .compactMap { $0 }
            category = itemName.map { name in
                administrativeNames.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
                    ? .locality : .poi
            } ?? .locality
        } else if placemark.subAdministrativeArea != nil || placemark.administrativeArea != nil {
            category = .administrativeArea
        } else if placemark.country != nil {
            category = .country
        } else {
            category = .poi
        }

        let displayName: String?
        switch category {
        case .poi: displayName = itemName
        case .locality: displayName = placemark.locality ?? itemName
        case .administrativeArea: displayName = placemark.subAdministrativeArea ?? placemark.administrativeArea ?? itemName
        case .country: displayName = placemark.country ?? itemName
        }
        guard let displayName, !displayName.isEmpty else { return nil }
        let coordinate = placemark.coordinate
        return PlaceSearchResult(
            provider: .mapKit,
            providerPlaceID: "\(displayName)|\(coordinate.latitude)|\(coordinate.longitude)",
            displayName: displayName,
            canonicalName: displayName,
            category: category,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            locality: placemark.locality,
            administrativeArea: placemark.administrativeArea ?? placemark.subAdministrativeArea,
            countryName: placemark.country,
            countryCode: placemark.isoCountryCode
        )
    }

    private static func photon(query: String, language: String) async throws -> [PlaceSearchResult] {
        guard let url = PlaceSearchEndpoint.photon(query: query, language: language) else {
            throw SearchError.invalidURL
        }
        return try PlaceSearchResponseDecoder.photon(await request(url))
    }

    private static func geoNames(query: String, language: String) async throws -> [PlaceSearchResult] {
        guard let url = PlaceSearchEndpoint.geoNames(query: query, language: language) else {
            throw SearchError.invalidURL
        }
        return try PlaceSearchResponseDecoder.geoNames(await request(url))
    }

    private static func request(_ url: URL) async throws -> Data {
        try await withTimeout {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200 ..< 300).contains(http.statusCode) else {
                throw SearchError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            return data
        }
    }

    private static func withTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SearchError.timeout
            }
            guard let value = try await group.next() else { throw SearchError.timeout }
            group.cancelAll()
            return value
        }
    }

    static func reverseLookup(
        _ coordinate: CLLocationCoordinate2D,
        preferredLocale: Locale = .current
    ) async throws -> MapSearchSelection {
        let geocoder = CLGeocoder()
        let placemarks = try await geocoder.reverseGeocodeLocation(
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            preferredLocale: preferredLocale
        )
        guard let placemark = placemarks.first else { throw SearchError.noResults }
        let displayName = placemark.locality ?? placemark.subAdministrativeArea
            ?? placemark.administrativeArea ?? placemark.country
            ?? String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
        let hierarchy = AdministrativeLocationHierarchy(
            locality: placemark.locality,
            subAdministrativeArea: placemark.subAdministrativeArea,
            administrativeArea: placemark.administrativeArea,
            country: placemark.country
        )
        return MapSearchSelection(
            displayName: displayName,
            coordinate: coordinate,
            candidateDatabaseNames: hierarchy.databaseCandidateNames,
            countryFallbackName: hierarchy.countryFallbackName,
            category: .locality,
            countryCode: placemark.isoCountryCode,
            localityName: placemark.locality
        )
    }

    private enum SearchError: Error {
        case invalidURL
        case noResults
        case timeout
        case httpStatus(Int)
    }
}
