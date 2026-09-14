import Foundation

enum L10n {
    static func text(_ key: String) -> String {
        localizedBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: languageIdentifier), arguments: arguments)
    }

    static func runtime(_ minutes: Int?) -> String {
        guard let minutes else { return "—" }
        return format("movie.runtime.minutes", minutes)
    }

    static func ratings(_ countText: String) -> String {
        format("movie.ratings.count", countText)
    }

    static func storyLocation(_ value: String) -> String {
        value.isEmpty ? text("movie.location.unknown") : value
    }

    static func year(_ year: Int) -> String {
        year < 0 ? format("year.bce", abs(year)) : String(year)
    }

    private static var languageIdentifier: String {
        InterfaceLanguageResolver.identifier(
            preference: UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "system",
            systemLanguages: Locale.preferredLanguages
        )
    }

    private static var localizedBundle: Bundle {
        guard let path = Bundle.main.path(forResource: languageIdentifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}
