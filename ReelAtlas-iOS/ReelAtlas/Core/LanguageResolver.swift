import Foundation

public enum LanguageResolver {
    public static func resolve(texts: [MovieText], preferred: String, original: String) -> MovieText? {
        guard !texts.isEmpty else { return nil }
        let preferredCode = normalizedCode(preferred)
        let originalCode = normalizedCode(original)
        if let exact = texts.first(where: { normalizedCode($0.languageCode) == preferredCode }) { return exact }
        if let english = texts.first(where: { normalizedCode($0.languageCode) == "en" }) { return english }
        if let originalText = texts.first(where: { normalizedCode($0.languageCode) == originalCode }) { return originalText }
        return texts.first
    }

    public static func normalizedCode(_ code: String) -> String {
        let lower = code.replacingOccurrences(of: "_", with: "-").lowercased()
        if lower == "zh" || lower.hasPrefix("zh-hans") || lower.hasPrefix("zh-cn") || lower.hasPrefix("zh-sg") { return "zh-Hans" }
        if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-mo") { return "zh-Hant" }
        return lower.split(separator: "-").first.map(String.init) ?? lower
    }
}

public enum InterfaceLanguageResolver {
    public static let supportedIdentifiers = ["en", "zh-Hans", "ja", "fr", "de", "es", "it", "pt", "ko"]

    public static func identifier(preference: String, systemLanguages: [String]) -> String {
        if preference != "system", supportedIdentifiers.contains(preference) { return preference }
        let system = systemLanguages.first.map(LanguageResolver.normalizedCode) ?? "en"
        return supportedIdentifiers.contains(system) ? system : "en"
    }
}
