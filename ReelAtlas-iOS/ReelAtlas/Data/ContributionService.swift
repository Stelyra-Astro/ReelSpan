import Foundation
import Security
import Combine

/// Submissions remain proposals until a human reviews them in Supabase.
struct ContributionRecord: Identifiable, Decodable, Sendable {
    let id: UUID
    let submission_kind: String
    let movie_qid: String?
    let tmdb_id: Int?
    let title: String?
    let time_entries: [String]
    let place_entries: [String]
    let concept_entries: [String]
    let status: String
    let moderation_note: String?
    let submitted_at: Date
    let reviewed_at: Date?
}

struct MissingFilm: Identifiable, Decodable, Sendable {
    let film: CatalogDiscoveryService.Film
    let has_time: Bool
    let has_place: Bool
    var id: String { film.movie_qid }
    var movie_qid: String { film.movie_qid }
    var title: String { film.title }
    private enum CodingKeys: String, CodingKey { case has_time, has_place }
    init(from decoder: Decoder) throws {
        film = try CatalogDiscoveryService.Film(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        has_time = try values.decode(Bool.self, forKey: .has_time)
        has_place = try values.decode(Bool.self, forKey: .has_place)
    }
    func movieData(language: String) -> MovieViewData { CatalogDiscoveryService.movieData(film, language: language) }
}

private enum ContributionIdentity {
    private static let service = "com.xiaoguiwk.ReelSpan.contributions"
    private static let account = "anonymous-submissions"

    static func token() -> UUID {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let text = String(data: data, encoding: .utf8),
           let saved = UUID(uuidString: text) { return saved }
        let token = UUID()
        let data = Data(token.uuidString.utf8)
        let insert: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: account,
                                     kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(insert as CFDictionary, nil)
        // A failed Keychain write must not issue a fresh identity for every request.
        if status != errSecSuccess {
            let key = "reelspan.contribution.backup-token"
            if let saved = UserDefaults.standard.string(forKey: key),
               let id = UUID(uuidString: saved) { return id }
            UserDefaults.standard.set(token.uuidString, forKey: key)
        }
        return token
    }
}

actor ContributionService {
    private let base = URL(string: "https://injisguyqfxfwgnbtghe.supabase.co/rest/v1/rpc")!
    private let key = "sb_publishable_OEEsH_hGwuWAsLoh95SiXw_mbj3D6i2"

    private func call(_ function: String, payload: [String: Any]) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(function))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw NSError(domain: "ReelSpan.Contribution", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: detail ?? "Could not reach the contribution service."])
        }
        return data
    }

    func submit(token: UUID, payload: [String: Any]) async throws {
        _ = try await call("reelspan_submit_contribution", payload: ["p_payload": payload, "p_token": token.uuidString])
    }

    func history(token: UUID) async throws -> [ContributionRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            for formats: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = formats
                if let date = formatter.date(from: text) { return date }
            }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid submission date")
        }
        return try decoder.decode([ContributionRecord].self,
                                  from: try await call("reelspan_my_contributions", payload: ["p_token": token.uuidString]))
    }

    /// A history page holds up to 200 rows; this RPC returns exact totals beyond the page.
    func historyCounts(token: UUID) async throws -> [String: Int] {
        let data = try await call("reelspan_my_contribution_counts", payload: ["p_token": token.uuidString])
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Int)? in
            guard let status = row["status"] as? String,
                  let total = (row["total"] as? NSNumber)?.intValue else { return nil }
            return (status, total)
        })
    }

    func missing(category: String, query: String = "", offset: Int) async throws -> [MissingFilm] {
        try JSONDecoder().decode([MissingFilm].self, from: try await call("reelspan_missing_film_cards", payload: [
            "p_category": category, "p_query": String(query.prefix(80)), "p_limit": 30, "p_offset": offset
        ]))
    }

    func existingFilms(title: String, tmdbID: String, imdbID: String) async throws -> [MovieViewData] {
        let data = try await call("reelspan_existing_film_candidates", payload: ["p_title": title, "p_tmdb_id": tmdbID, "p_imdb_id": imdbID.lowercased()])
        return try JSONDecoder().decode([CatalogDiscoveryService.Film].self, from: data).map {
            CatalogDiscoveryService.movieData($0, language: Locale.preferredLanguages.first ?? "en")
        }
    }

    func missingCounts() async throws -> [String: Int] {
        let rows = try JSONSerialization.jsonObject(with: try await call("reelspan_missing_counts", payload: [:])) as? [[String: Any]]
        return Dictionary(uniqueKeysWithValues: (rows ?? []).compactMap { row -> (String, Int)? in
            guard let kind = row["category"] as? String, let count = row["film_count"] as? Int else { return nil }
            return (kind, count)
        })
    }
}

@MainActor
final class ContributionStore: ObservableObject {
    @Published private(set) var history: [ContributionRecord] = []
    @Published private(set) var historyCounts: [String: Int] = [:]
    @Published private(set) var missingCounts: [String: Int] = [:]
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var missingCountsError: String?
    @Published var errorMessage: String?
    private let service = ContributionService()
    private lazy var token = ContributionIdentity.token()

    var pendingCount: Int { historyCounts["pending"] ?? history.filter { $0.status == "pending" }.count }
    var acceptedCount: Int { historyCounts["accepted"] ?? history.filter { $0.status == "accepted" }.count }
    var rejectedCount: Int { historyCounts["rejected"] ?? history.filter { $0.status == "rejected" }.count }
    var totalCount: Int { pendingCount + acceptedCount + rejectedCount }

    func refresh() async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let result = try await service.history(token: token)
            history = result
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        if let counts = try? await service.historyCounts(token: token) { historyCounts = counts }
        await refreshMissingCounts()
    }

    func refreshMissingCounts() async {
        do { missingCounts = try await service.missingCounts(); missingCountsError = nil }
        catch { missingCountsError = "Could not refresh film counts. Pull to retry." }
    }

    func existingFilms(title: String, tmdbID: String, imdbID: String) async throws -> [MovieViewData] {
        try await service.existingFilms(title: title, tmdbID: tmdbID, imdbID: imdbID)
    }

    func submit(existingMovieQID: String?, title: String, tmdbID: String, imdbID: String,
                times: [String], places: [String], concepts: [String]) async throws {
        let payload: [String: Any]
        if let existingMovieQID {
            payload = ["kind": "existing", "movie_qid": existingMovieQID,
                       "time_entries": times, "place_entries": places]
        } else {
            let existing = try await service.existingFilms(title: title, tmdbID: tmdbID, imdbID: imdbID)
            if existing.contains(where: { ContributionDuplicatePolicy.isExisting(title: title, tmdbID: tmdbID, imdbID: imdbID,
                candidateTitle: $0.title, candidateTMDBID: $0.tmdbID, candidateIMDbID: $0.imdbID, candidateOriginalTitle: $0.catalogOriginalTitle) }) {
                throw NSError(domain: "ReelSpan.Contribution", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Film already in ReelSpan. Select it to correct story details instead."])
            }
            payload = ["kind": "new", "title": title, "tmdb_id": tmdbID,
                       "imdb_id": imdbID, "time_entries": times, "place_entries": places,
                       "concept_entries": concepts]
        }
        try await service.submit(token: token, payload: payload)
        await refresh()
    }

    func missing(category: String, query: String = "", offset: Int) async throws -> [MissingFilm] {
        try await service.missing(category: category, query: query, offset: offset)
    }
}
