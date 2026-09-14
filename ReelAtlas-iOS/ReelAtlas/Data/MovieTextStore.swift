import Foundation
import SQLite3

final class MovieTextStore {
    private let languagesDirectory: URL
    private var databases: [String: SQLiteDatabase] = [:]

    init(supportRoot: URL) throws {
        languagesDirectory = supportRoot.appendingPathComponent("Languages", isDirectory: true)
        try FileManager.default.createDirectory(at: languagesDirectory, withIntermediateDirectories: true)
    }

    func resolve(
        movieID: Int,
        preferredLanguage: String,
        originalLanguage: String,
        originalTitle: String,
        originalOverview: String
    ) -> MovieText {
        let original = MovieText(
            languageCode: LanguageResolver.normalizedCode(originalLanguage),
            title: originalTitle,
            overview: originalOverview
        )

        var texts: [MovieText] = [original]
        var seen = Set<String>([LanguageResolver.normalizedCode(original.languageCode)])
        let requested = [preferredLanguage, "en", originalLanguage].map(LanguageResolver.normalizedCode)

        for code in requested where seen.insert(code).inserted {
            if let text = text(movieID: movieID, languageCode: code) {
                texts.append(text)
            }
        }
        return LanguageResolver.resolve(texts: texts, preferred: preferredLanguage, original: originalLanguage) ?? original
    }

    private func text(movieID: Int, languageCode: String) -> MovieText? {
        guard let database = database(for: languageCode),
              let statement = try? database.prepare(
                "SELECT title,overview FROM movie_texts WHERE movie_id=? LIMIT 1",
                bindings: [.int(movieID)]
              ) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard (try? database.step(statement)) == true else { return nil }
        return MovieText(
            languageCode: languageCode,
            title: database.text(statement, 0) ?? "",
            overview: database.text(statement, 1) ?? ""
        )
    }

    private func database(for languageCode: String) -> SQLiteDatabase? {
        let code = LanguageResolver.normalizedCode(languageCode)
        if let cached = databases[code] { return cached }

        let filename = "ContentText_\(code)"
        let downloaded = languagesDirectory.appendingPathComponent("\(filename).sqlite")
        let sourceURL: URL?
        if FileManager.default.fileExists(atPath: downloaded.path) {
            sourceURL = downloaded
        } else {
            sourceURL = Bundle.main.url(forResource: filename, withExtension: "sqlite")
        }

        guard let sourceURL, let database = try? SQLiteDatabase(url: sourceURL, readOnly: true) else { return nil }
        databases[code] = database
        return database
    }
}
