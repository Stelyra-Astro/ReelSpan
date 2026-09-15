import Foundation
import CoreLocation

/// Search must not inherit the device's current regional bias. MapKit still ranks
/// results, but a world-sized region lets place queries resolve outside China.
public enum AdministrativePlaceSearchPolicy {
    public static let regionCenterLatitude = 0.0
    public static let regionCenterLongitude = 0.0
    public static let latitudeDelta = 180.0
    public static let longitudeDelta = 360.0

    public static var regionCenter: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: regionCenterLatitude, longitude: regionCenterLongitude)
    }
}

public struct LocationFallbackResolver: Sendable {
    private let parentByID: [String: String]

    public init(parentByID: [String: String]) {
        self.parentByID = parentByID
    }

    public func firstLocationWithResults(start: String, countResults: (String) -> Int) -> LocationMatch? {
        var current: String? = start
        var depth = 0
        var visited = Set<String>()
        while let id = current, !visited.contains(id) {
            visited.insert(id)
            if countResults(id) > 0 { return LocationMatch(locationID: id, fallbackDepth: depth) }
            current = parentByID[id]
            depth += 1
        }
        return nil
    }
}

/// The administrative path for a MapKit result, ordered from the most specific
/// indexed place to its country. POI and neighborhood names are intentionally
/// accepted but not used so search never falls back through businesses or
/// residential subdivisions.
public struct AdministrativeLocationHierarchy: Sendable {
    public let databaseCandidateNames: [String]
    public let countryFallbackName: String?

    public init(
        pointOfInterestName: String? = nil,
        locality: String?,
        subLocality: String? = nil,
        subAdministrativeArea: String?,
        administrativeArea: String?,
        country: String?
    ) {
        _ = pointOfInterestName
        _ = subLocality
        countryFallbackName = country?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        var seen = Set<String>()
        databaseCandidateNames = [locality, subAdministrativeArea, administrativeArea, country]
            .compactMap { value in
                guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !trimmed.isEmpty else { return nil }
                return trimmed
            }
            .filter { seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted }
    }
}


public enum AdministrativePlaceNameMatcher {
    public static func rank(query: String, names: [String]) -> Int? {
        let needle = normalized(query)
        guard needle.count >= 2 else { return nil }
        let values = names.map(normalized).filter { !$0.isEmpty }
        if values.contains(needle) { return 0 }
        if values.contains(where: { $0.hasPrefix(needle) }) { return 1 }
        if values.contains(where: { value in
            value.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .contains(where: { $0.hasPrefix(needle) })
        }) { return 2 }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
