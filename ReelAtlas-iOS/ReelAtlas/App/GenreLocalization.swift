import Foundation

enum GenreLocalization {
    static func displayName(_ rawName: String) -> String {
        let normalized = GenreDisplayName.normalized(rawName)
        guard let key = GenreDisplayName.localizationKey(for: rawName) else { return normalized }
        return L10n.text(key)
    }
}
