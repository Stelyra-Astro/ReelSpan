import Foundation
import MapKit
import CoreLocation
import Combine

struct MapSearchSuggestion: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    fileprivate let completion: MKLocalSearchCompletion?
    fileprivate let selection: MapSearchSelection?

    init(completion: MKLocalSearchCompletion) {
        title = completion.title
        subtitle = completion.subtitle
        id = "mapkit|\(title)|\(subtitle)"
        self.completion = completion
        selection = nil
    }

    init(title: String, subtitle: String, selection: MapSearchSelection) {
        self.id = "resolved|\(title)|\(subtitle)"
        self.title = title
        self.subtitle = subtitle
        completion = nil
        self.selection = selection
    }
}

@MainActor
final class AdministrativePlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [MapSearchSuggestion] = []

    private let completer = MKLocalSearchCompleter()
    private var currentQuery = ""
    private var requestTracker = SearchRequestTracker()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address]
        completer.region = MapSearchService.globalSearchRegion
        if #available(iOS 18.0, *) {
            completer.addressFilter = MKAddressFilter(including: [
                .country,
                .administrativeArea,
                .subAdministrativeArea,
                .locality
            ])
        }
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        currentQuery = trimmed
        _ = requestTracker.update(trimmed)
        guard trimmed.count >= 2 else {
            suggestions = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = trimmed
    }

    func clear() {
        currentQuery = ""
        _ = requestTracker.update("")
        suggestions = []
        completer.queryFragment = ""
    }

    func submit(query: String) async {
        update(query: query)
        let requestedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestedQuery.count >= 2,
              requestTracker.accepts(requestedQuery) else { return }
        guard let resolved = try? await MapSearchService.suggestions(for: query) else { return }
        guard requestTracker.accepts(requestedQuery) else { return }
        var seen = Set(suggestions.map(\.id))
        suggestions.append(contentsOf: resolved.filter { seen.insert($0.id).inserted })
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor [weak self] in
            guard let self, self.currentQuery.count >= 2 else { return }
            var seen = Set<String>()
            self.suggestions = results.compactMap { completion in
                guard AdministrativePlaceNameMatcher.rank(
                    query: self.currentQuery,
                    names: [completion.title, completion.subtitle]
                ) != nil else { return nil }
                let key = "\(completion.title)|\(completion.subtitle)".folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                guard seen.insert(key).inserted else { return nil }
                return MapSearchSuggestion(completion: completion)
            }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.suggestions = [] }
    }
}

struct MapSearchSelection {
    let displayName: String
    let coordinate: CLLocationCoordinate2D
    let candidateDatabaseNames: [String]
    let countryFallbackName: String?
}

enum MapSearchService {
    static let globalSearchRegion = MKCoordinateRegion(
        center: AdministrativePlaceSearchPolicy.regionCenter,
        span: MKCoordinateSpan(
            latitudeDelta: AdministrativePlaceSearchPolicy.latitudeDelta,
            longitudeDelta: AdministrativePlaceSearchPolicy.longitudeDelta
        )
    )

    static func resolve(_ suggestion: MapSearchSuggestion) async throws -> MapSearchSelection {
        if let selection = suggestion.selection { return selection }
        guard let completion = suggestion.completion else {
            throw NSError(domain: "ReelAtlas.MapSearch", code: 404, userInfo: [NSLocalizedDescriptionKey: L10n.text("home.search_failed")])
        }
        let request = MKLocalSearch.Request(completion: completion)
        request.resultTypes = [.address]
        if #available(iOS 18.0, *) {
            request.addressFilter = MKAddressFilter(including: [
                .country,
                .administrativeArea,
                .subAdministrativeArea,
                .locality
            ])
        }
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first(where: { item in
            let placemark = item.placemark
            return placemark.locality != nil ||
                placemark.subAdministrativeArea != nil ||
                placemark.administrativeArea != nil ||
                placemark.country != nil
        }) else {
            throw NSError(domain: "ReelAtlas.MapSearch", code: 404, userInfo: [NSLocalizedDescriptionKey: L10n.text("home.search_failed")])
        }
        let p = item.placemark
        let hierarchy = AdministrativeLocationHierarchy(
            pointOfInterestName: item.name,
            locality: p.locality,
            subLocality: p.subLocality,
            subAdministrativeArea: p.subAdministrativeArea,
            administrativeArea: p.administrativeArea,
            country: p.country
        )
        let display = p.locality ?? p.subAdministrativeArea ?? p.administrativeArea ?? p.country ?? suggestion.title
        return MapSearchSelection(
            displayName: display,
            coordinate: p.coordinate,
            candidateDatabaseNames: hierarchy.databaseCandidateNames,
            countryFallbackName: hierarchy.countryFallbackName
        )
    }

    static func suggestions(for query: String) async throws -> [MapSearchSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.address]
        request.region = globalSearchRegion
        if #available(iOS 18.0, *) {
            request.addressFilter = MKAddressFilter(including: [
                .country,
                .administrativeArea,
                .subAdministrativeArea,
                .locality
            ])
        }

        let response = try await MKLocalSearch(request: request).start()
        var seen = Set<String>()
        return response.mapItems.compactMap { item in
            let p = item.placemark
            let hierarchy = AdministrativeLocationHierarchy(
                pointOfInterestName: item.name,
                locality: p.locality,
                subLocality: p.subLocality,
                subAdministrativeArea: p.subAdministrativeArea,
                administrativeArea: p.administrativeArea,
                country: p.country
            )
            guard AdministrativePlaceNameMatcher.rank(query: trimmed, names: hierarchy.databaseCandidateNames) != nil,
                  let title = hierarchy.databaseCandidateNames.first else { return nil }
            let subtitle = hierarchy.databaseCandidateNames.dropFirst().joined(separator: " · ")
            let key = "\(title)|\(subtitle)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            let selection = MapSearchSelection(
                displayName: title,
                coordinate: p.coordinate,
                candidateDatabaseNames: hierarchy.databaseCandidateNames,
                countryFallbackName: hierarchy.countryFallbackName
            )
            return MapSearchSuggestion(title: title, subtitle: subtitle, selection: selection)
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
        guard let p = placemarks.first else {
            throw NSError(domain: "ReelAtlas.MapSearch", code: 404, userInfo: [NSLocalizedDescriptionKey: L10n.text("home.search_failed")])
        }
        let display = p.locality ?? p.subAdministrativeArea ?? p.administrativeArea ?? p.country ?? String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
        let hierarchy = AdministrativeLocationHierarchy(
            pointOfInterestName: p.name,
            locality: p.locality,
            subLocality: p.subLocality,
            subAdministrativeArea: p.subAdministrativeArea,
            administrativeArea: p.administrativeArea,
            country: p.country
        )
        return MapSearchSelection(
            displayName: display,
            coordinate: coordinate,
            candidateDatabaseNames: hierarchy.databaseCandidateNames,
            countryFallbackName: hierarchy.countryFallbackName
        )
    }
}
