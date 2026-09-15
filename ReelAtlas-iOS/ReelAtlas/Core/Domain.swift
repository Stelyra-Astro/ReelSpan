import Foundation

struct ContentBootstrapScope: Equatable, Sendable {
    let movieQIDs: [String]

    init?(movieQIDs: [String]) {
        let normalized = Array(Set(movieQIDs.filter { !$0.isEmpty })).sorted()
        guard !normalized.isEmpty else { return nil }
        self.movieQIDs = normalized
    }

    var postgRESTMovieFilter: String {
        Self.postgRESTFilter(qids: movieQIDs)!
    }

    static func postgRESTFilter(qids: [String]) -> String? {
        let normalized = Array(Set(qids.filter { !$0.isEmpty })).sorted()
        guard !normalized.isEmpty else { return nil }
        return "in.(\(normalized.joined(separator: ",")))"
    }
}

struct ContentBootstrapGate: Sendable {
    private var contentIsReady = false
    private var initialSelectionWasRequested = false
    private var initialSelectionWasReleased = false

    mutating func requestInitialSelection() -> Bool {
        initialSelectionWasRequested = true
        return releaseIfPossible()
    }

    mutating func markContentReady() -> Bool {
        contentIsReady = true
        return releaseIfPossible()
    }

    private mutating func releaseIfPossible() -> Bool {
        guard contentIsReady, initialSelectionWasRequested, !initialSelectionWasReleased else {
            return false
        }
        initialSelectionWasReleased = true
        return true
    }
}

public enum GenreDisplayName {
    private static let localizationKeyByEnglishName: [String: String] = [
        "action": "genre.action",
        "adventure": "genre.adventure",
        "animation": "genre.animation",
        "comedy": "genre.comedy",
        "crime": "genre.crime",
        "documentary": "genre.documentary",
        "drama": "genre.drama",
        "family": "genre.family",
        "fantasy": "genre.fantasy",
        "history": "genre.history",
        "horror": "genre.horror",
        "music": "genre.music",
        "mystery": "genre.mystery",
        "romance": "genre.romance",
        "science fiction": "genre.science_fiction",
        "tv movie": "genre.tv_movie",
        "thriller": "genre.thriller",
        "war": "genre.war",
        "western": "genre.western",
        "biography": "genre.biography"
    ]

    public static func normalized(_ rawName: String) -> String {
        let suffix = " film"
        guard rawName.lowercased().hasSuffix(suffix) else { return rawName }
        return String(rawName.dropLast(suffix.count))
    }

    public static func localizationKey(for rawName: String) -> String? {
        localizationKeyByEnglishName[normalized(rawName).lowercased()]
    }
}

enum IMDbDestination {
    static func url(imdbID: String?, title: String) -> URL {
        let candidate = imdbID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if candidate.range(of: #"^tt[0-9]+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return URL(string: "https://www.imdb.com/title/\(candidate.lowercased())/")!
        }

        var components = URLComponents(string: "https://www.imdb.com/find/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: title),
            URLQueryItem(name: "s", value: "tt")
        ]
        return components.url!
    }
}

enum ReelSpanLinks {
    static let website = URL(string: "https://stelyra-astro.github.io/ReelSpan/")!
    static let privacy = URL(string: "https://stelyra-astro.github.io/ReelSpan/privacy/")!
    static let terms = URL(string: "https://stelyra-astro.github.io/ReelSpan/terms/")!
    static let supportEmail = "Stelyra-Astro@proton.me"
    static let supportEmailURL = URL(string: "mailto:\(supportEmail)")!
}

struct ICloudBackupManifest: Codable, Equatable {
    let favoriteMovieQIDs: [String]
    let interfaceLanguage: String
    let updatedAt: Date

    init(favoriteMovieQIDs: [String], interfaceLanguage: String, updatedAt: Date) {
        self.favoriteMovieQIDs = Array(Set(favoriteMovieQIDs)).sorted()
        self.interfaceLanguage = interfaceLanguage
        self.updatedAt = updatedAt
    }
}

public struct StoryTimeRange: Codable, Hashable, Sendable {
    public let startYear: Int
    public let endYear: Int
    public let sourcePeriodQID: String?
    public let normalizationType: String?
    public let confidence: Double

    public init(startYear: Int, endYear: Int, sourcePeriodQID: String? = nil, normalizationType: String? = nil, confidence: Double = 1.0) {
        self.startYear = min(startYear, endYear)
        self.endYear = max(startYear, endYear)
        self.sourcePeriodQID = sourcePeriodQID
        self.normalizationType = normalizationType
        self.confidence = confidence
    }

    public var displayText: String {
        startYear == endYear ? HistoricalYearFormatter.string(startYear) : "\(HistoricalYearFormatter.string(startYear))–\(HistoricalYearFormatter.string(endYear))"
    }
}

public struct MovieText: Codable, Hashable, Sendable {
    public let languageCode: String
    public let title: String
    public let overview: String

    public init(languageCode: String, title: String, overview: String) {
        self.languageCode = languageCode
        self.title = title
        self.overview = overview
    }
}

public struct LocationMatch: Equatable, Sendable {
    public let locationID: String
    public let fallbackDepth: Int
}

public struct CSVNamedEntity: Codable, Equatable, Hashable, Sendable {
    public let qid: String
    public let name: String

    public init(qid: String, name: String) {
        self.qid = qid
        self.name = name
    }
}

public enum CSVContentDecoder {
    public static func labelValues(json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let labels = try? JSONDecoder().decode([String: String].self, from: data) else {
            return []
        }
        return Array(labels.values)
    }

    public static func localizedLabel(json: String, preferredLanguage: String) -> String? {
        guard let data = json.data(using: .utf8),
              let labels = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        let lowercased = Dictionary(uniqueKeysWithValues: labels.map { ($0.key.lowercased(), $0.value) })
        let exact = preferredLanguage.replacingOccurrences(of: "_", with: "-").lowercased()
        if let value = lowercased[exact] { return value }

        switch LanguageResolver.normalizedCode(preferredLanguage) {
        case "zh-Hans":
            if let value = lowercased["zh-hans"] ?? lowercased["zh"] { return value }
        case "zh-Hant":
            if let value = lowercased["zh-hant"] { return value }
        case let language:
            if let value = lowercased[language.lowercased()] { return value }
        }
        return lowercased["en"]
    }

    public static func namedEntities(json: String) -> [CSVNamedEntity] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CSVNamedEntity].self, from: data)) ?? []
    }
}

public enum SearchTextMatcher {
    public static func rank(query: String, fields: [String]) -> Int? {
        let needle = normalized(query)
        guard needle.count >= 2 else { return nil }
        let values = fields.map(normalized).filter { !$0.isEmpty }
        if values.contains(needle) { return 0 }
        if values.contains(where: { value in
            value.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .contains(where: { $0.hasPrefix(needle) }) || hasBoundaryPrefix(needle, in: value)
        }) { return 1 }
        if values.contains(where: { $0.contains(needle) }) { return 2 }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func hasBoundaryPrefix(_ needle: String, in value: String) -> Bool {
        var searchStart = value.startIndex
        while searchStart < value.endIndex,
              let range = value.range(of: needle, range: searchStart..<value.endIndex) {
            if range.lowerBound == value.startIndex { return true }
            let previous = value[value.index(before: range.lowerBound)]
            if previous.unicodeScalars.allSatisfy({ !CharacterSet.alphanumerics.contains($0) }) {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }
}
