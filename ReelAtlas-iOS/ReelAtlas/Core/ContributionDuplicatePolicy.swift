import Foundation

public enum ContributionDuplicatePolicy {
    public static func isExisting(title: String, tmdbID: String, imdbID: String,
                                  candidateTitle: String, candidateTMDBID: Int?, candidateIMDbID: String?, candidateOriginalTitle: String? = nil) -> Bool {
        let tmdb = tmdbID.trimmingCharacters(in: .whitespacesAndNewlines)
        let imdb = imdbID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let id = Int(tmdb), id == candidateTMDBID { return true }
        if !imdb.isEmpty && imdb == candidateIMDbID?.lowercased() { return true }
        guard tmdb.isEmpty, imdb.isEmpty else { return false }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == candidateTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            || normalized == candidateOriginalTitle?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public struct ContributionTimeRange: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var start: String
    public var end: String
    public init(start: String = "", end: String = "") { id = UUID(); self.start = start; self.end = end }
    public var isEmpty: Bool {
        start.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && end.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var entry: String? {
        guard let start = Int(start.trimmingCharacters(in: .whitespacesAndNewlines)),
              let end = Int(end.trimmingCharacters(in: .whitespacesAndNewlines)),
              (-999999...999999).contains(start), (-999999...999999).contains(end), end >= start else { return nil }
        return start == end ? String(start) : "\(start)–\(end)"
    }
}
