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

public enum PlaceSearchProvider: String, Equatable, Sendable {
    case mapKit
    case photon
    case geoNames
}

public enum PlaceSearchCategory: String, Equatable, Sendable {
    case country
    case administrativeArea
    case locality
    case poi
}

public enum PlaceMovieFilterScope: Equatable, Sendable {
    case place(candidateNames: [String])
    case country(countryCode: String, candidateNames: [String])
}

public struct PlaceSearchBounds: Equatable, Sendable {
    public let south: Double
    public let west: Double
    public let north: Double
    public let east: Double

    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south
        self.west = west
        self.north = north
        self.east = east
    }
}

public struct PlaceSearchViewport: Equatable, Sendable {
    public let centerLatitude: Double
    public let centerLongitude: Double
    public let latitudeDelta: Double
    public let longitudeDelta: Double
}

public struct PlaceSearchResult: Equatable, Sendable {
    public let provider: PlaceSearchProvider
    public let providerPlaceID: String
    public let displayName: String
    public let canonicalName: String
    public let category: PlaceSearchCategory
    public let latitude: Double
    public let longitude: Double
    public let locality: String?
    public let administrativeArea: String?
    public let countryName: String?
    public let countryCode: String?
    public let bounds: PlaceSearchBounds?

    public init(
        provider: PlaceSearchProvider,
        providerPlaceID: String,
        displayName: String,
        canonicalName: String,
        category: PlaceSearchCategory,
        latitude: Double,
        longitude: Double,
        locality: String?,
        administrativeArea: String?,
        countryName: String?,
        countryCode: String?,
        bounds: PlaceSearchBounds? = nil
    ) {
        self.provider = provider
        self.providerPlaceID = providerPlaceID
        self.displayName = displayName
        self.canonicalName = canonicalName
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.locality = locality
        self.administrativeArea = administrativeArea
        self.countryName = countryName
        self.countryCode = countryCode
        self.bounds = bounds
    }

    public var hasValidCoordinate: Bool {
        latitude.isFinite && longitude.isFinite &&
            (-90 ... 90).contains(latitude) && (-180 ... 180).contains(longitude)
    }

    public var storyLocationCandidateNames: [String] {
        let values: [String?]
        switch category {
        case .poi:
            guard locality?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return []
            }
            values = [locality, administrativeArea, countryName]
        case .locality:
            values = [locality, displayName, canonicalName, administrativeArea, countryName]
        case .administrativeArea:
            values = [displayName, canonicalName, administrativeArea, countryName]
        case .country:
            values = [displayName, canonicalName, countryName]
        }
        var seen = Set<String>()
        return values.compactMap { value in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return seen.insert(key).inserted ? trimmed : nil
        }
    }

    public var movieFilterScope: PlaceMovieFilterScope {
        if category == .country, let countryCode, !countryCode.isEmpty {
            return .country(countryCode: countryCode.uppercased(), candidateNames: storyLocationCandidateNames)
        }
        return .place(candidateNames: storyLocationCandidateNames)
    }

    public var parentDisplayNames: [String] {
        let values: [String?]
        switch category {
        case .country:
            values = []
        case .administrativeArea:
            values = [countryName]
        case .locality:
            values = [administrativeArea, countryName]
        case .poi:
            values = [locality, administrativeArea, countryName]
        }
        let excluded = Set([displayName, canonicalName].map(Self.normalizedName))
        var seen = Set<String>()
        return values.compactMap { value in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            let key = Self.normalizedName(trimmed)
            return !excluded.contains(key) && seen.insert(key).inserted ? trimmed : nil
        }
    }

    private static func normalizedName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

public enum PlaceSearchPresentation {
    public static func showsTemporaryMarker(for category: PlaceSearchCategory) -> Bool {
        category == .poi
    }
}

public enum CountryCodeResolver {
    public static func code(candidateNames: [String]) -> String? {
        let needles = Set(candidateNames.map(normalized).filter { !$0.isEmpty })
        guard !needles.isEmpty else { return nil }
        let commonAliases = [
            "CN": ["China", "中国", "中国大陆"],
            "US": ["United States", "United States of America", "USA", "美国"],
            "GB": ["United Kingdom", "UK", "英国"]
        ]
        for (code, aliases) in commonAliases where !needles.isDisjoint(with: aliases.map(normalized)) {
            return code
        }
        let locales = [Locale(identifier: "en_US"), Locale(identifier: "zh_Hans")]
        for region in Locale.Region.isoRegions {
            let code = region.identifier.uppercased()
            let names = locales.compactMap { $0.localizedString(forRegionCode: code) }.map(normalized)
            if names.contains(where: needles.contains) { return code }
        }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public enum PlaceSearchViewportPolicy {
    public static func viewport(
        category: PlaceSearchCategory,
        latitude: Double,
        longitude: Double,
        bounds: PlaceSearchBounds?
    ) -> PlaceSearchViewport {
        if let bounds,
           bounds.north >= bounds.south,
           bounds.east >= bounds.west {
            return PlaceSearchViewport(
                centerLatitude: (bounds.north + bounds.south) / 2,
                centerLongitude: (bounds.east + bounds.west) / 2,
                latitudeDelta: max(0.02, (bounds.north - bounds.south) * 1.2),
                longitudeDelta: max(0.02, (bounds.east - bounds.west) * 1.2)
            )
        }
        let delta: (Double, Double)
        switch category {
        case .country: delta = (45, 60)
        case .administrativeArea: delta = (8, 8)
        case .locality: delta = (0.45, 0.45)
        case .poi: delta = (0.05, 0.05)
        }
        return PlaceSearchViewport(
            centerLatitude: latitude,
            centerLongitude: longitude,
            latitudeDelta: delta.0,
            longitudeDelta: delta.1
        )
    }
}

public enum PlaceSearchEndpoint {
    public static func photon(query: String, language: String) -> URL? {
        endpoint(
            base: "https://photon.komoot.io/api/",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "lang", value: language)
            ]
        )
    }

    public static func geoNames(query: String, language: String) -> URL? {
        endpoint(
            base: "https://secure.geonames.org/searchJSON",
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "maxRows", value: "10"),
                URLQueryItem(name: "lang", value: language),
                URLQueryItem(name: "username", value: "Stelyra")
            ]
        )
    }

    private static func endpoint(base: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = queryItems
        return components.url
    }
}

public enum PlaceSearchResponseDecoder {
    public static func photon(_ data: Data) throws -> [PlaceSearchResult] {
        let response = try JSONDecoder().decode(PhotonResponse.self, from: data)
        return response.features.compactMap { feature in
            guard feature.geometry.coordinates.count >= 2,
                  let name = feature.properties.name?.trimmedNonEmpty else { return nil }
            let longitude = feature.geometry.coordinates[0]
            let latitude = feature.geometry.coordinates[1]
            let type = feature.properties.type?.lowercased() ?? ""
            let category: PlaceSearchCategory
            switch type {
            case "country": category = .country
            case "state", "county", "district", "province", "region": category = .administrativeArea
            case "city", "town", "village", "municipality", "locality": category = .locality
            default: category = .poi
            }
            let extent = feature.properties.extent
            let bounds = extent.flatMap { values -> PlaceSearchBounds? in
                guard values.count >= 4 else { return nil }
                return PlaceSearchBounds(south: values[1], west: values[0], north: values[3], east: values[2])
            }
            return PlaceSearchResult(
                provider: .photon,
                providerPlaceID: "\(feature.properties.osmType ?? "?")|\(feature.properties.osmID.map(String.init) ?? name)",
                displayName: name,
                canonicalName: name,
                category: category,
                latitude: latitude,
                longitude: longitude,
                locality: category == .locality ? name : feature.properties.city?.trimmedNonEmpty,
                administrativeArea: feature.properties.state?.trimmedNonEmpty
                    ?? feature.properties.county?.trimmedNonEmpty
                    ?? feature.properties.district?.trimmedNonEmpty,
                countryName: feature.properties.country?.trimmedNonEmpty,
                countryCode: feature.properties.countryCode?.uppercased(),
                bounds: bounds
            )
        }
    }

    public static func geoNames(_ data: Data) throws -> [PlaceSearchResult] {
        let response = try JSONDecoder().decode(GeoNamesResponse.self, from: data)
        return response.geonames.compactMap { item in
            guard let latitude = Double(item.latitude), let longitude = Double(item.longitude),
                  let displayName = item.name.trimmedNonEmpty else { return nil }
            let featureCode = item.featureCode.uppercased()
            let category: PlaceSearchCategory
            if featureCode.hasPrefix("PCL") {
                category = .country
            } else if item.featureClass.uppercased() == "A" {
                category = .administrativeArea
            } else if item.featureClass.uppercased() == "P" {
                category = .locality
            } else {
                category = .poi
            }
            return PlaceSearchResult(
                provider: .geoNames,
                providerPlaceID: String(item.geonameID),
                displayName: displayName,
                canonicalName: item.toponymName.trimmedNonEmpty ?? displayName,
                category: category,
                latitude: latitude,
                longitude: longitude,
                locality: category == .locality ? displayName : nil,
                administrativeArea: item.adminName1?.trimmedNonEmpty,
                countryName: item.countryName?.trimmedNonEmpty,
                countryCode: item.countryCode?.uppercased()
            )
        }
    }

    private struct PhotonResponse: Decodable {
        let features: [Feature]

        struct Feature: Decodable {
            let geometry: Geometry
            let properties: Properties
        }
        struct Geometry: Decodable { let coordinates: [Double] }
        struct Properties: Decodable {
            let osmType: String?
            let osmID: Int64?
            let type: String?
            let name: String?
            let city: String?
            let state: String?
            let county: String?
            let district: String?
            let country: String?
            let countryCode: String?
            let extent: [Double]?

            enum CodingKeys: String, CodingKey {
                case osmType = "osm_type"
                case osmID = "osm_id"
                case type, name, city, state, county, district, country, extent
                case countryCode = "countrycode"
            }
        }
    }

    private struct GeoNamesResponse: Decodable {
        let geonames: [Item]

        struct Item: Decodable {
            let geonameID: Int64
            let name: String
            let toponymName: String
            let latitude: String
            let longitude: String
            let countryCode: String?
            let countryName: String?
            let adminName1: String?
            let featureClass: String
            let featureCode: String

            enum CodingKeys: String, CodingKey {
                case geonameID = "geonameId"
                case name, toponymName, countryCode, countryName, adminName1
                case latitude = "lat"
                case longitude = "lng"
                case featureClass = "fcl"
                case featureCode = "fcode"
            }
        }
    }
}

public enum PlaceSearchPipeline {
    public typealias Provider = @Sendable () async throws -> [PlaceSearchResult]

    public static func search(
        query: String,
        mapKit: Provider,
        photon: Provider,
        geoNames: Provider
    ) async throws -> [PlaceSearchResult] {
        do {
            let results = try await mapKit().filter(\.hasValidCoordinate)
            let relevant = results.filter { PlaceSearchRelevance.isRelevant(query: query, result: $0) }
            if !relevant.isEmpty { return relevant }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
        }

        do {
            let results = try await photon().filter(\.hasValidCoordinate)
            let relevant = results.filter { PlaceSearchRelevance.isRelevant(query: query, result: $0) }
            if !relevant.isEmpty { return relevant }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
        }

        do {
            return try await geoNames().filter(\.hasValidCoordinate)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return []
        }
    }
}

public enum PlaceSearchRelevance {
    public static func isRelevant(query: String, result: PlaceSearchResult) -> Bool {
        let needle = normalized(query)
        guard needle.count >= 2 else { return false }
        let names = [
            result.displayName,
            result.canonicalName,
            result.locality,
            result.administrativeArea,
            result.countryName
        ].compactMap { $0 }.map(normalized)
        if result.category == .poi {
            return names.prefix(2).contains(needle)
        }
        return names.contains { value in
            value == needle || value.hasPrefix(needle) ||
                value.components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .contains(where: { $0.hasPrefix(needle) })
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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

/// A search result's viewport is a one-shot camera instruction. Once the user
/// starts navigating the map it must no longer be allowed to re-center it.
public struct MapViewportIntent: Equatable, Sendable {
    public private(set) var viewport: PlaceSearchViewport?

    public init(viewport: PlaceSearchViewport? = nil) {
        self.viewport = viewport
    }

    public mutating func select(_ viewport: PlaceSearchViewport) {
        selectionResolved(viewport, source: .searchResult)
    }

    public mutating func selectionResolved(
        _ viewport: PlaceSearchViewport,
        source: MapSelectionSource
    ) {
        switch source {
        case .searchResult:
            self.viewport = viewport
        case .mapNavigation:
            self.viewport = nil
        }
    }

    public mutating func userNavigationStarted() {
        viewport = nil
    }
}

public enum MapSelectionSource: Equatable, Sendable {
    case searchResult
    case mapNavigation
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
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
