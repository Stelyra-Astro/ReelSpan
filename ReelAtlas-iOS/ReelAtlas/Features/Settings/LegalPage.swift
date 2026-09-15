import Foundation

enum LegalPage: String, Identifiable, Hashable {
    case privacy, terms, help, about, sources, tmdb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: return L10n.text("legal.privacy.title")
        case .terms: return L10n.text("legal.terms.title")
        case .help: return L10n.text("legal.help.title")
        case .about: return L10n.text("legal.about.title")
        case .sources: return L10n.text("legal.sources.title")
        case .tmdb: return L10n.text("legal.tmdb.title")
        }
    }

    var body: String {
        switch self {
        case .privacy: return L10n.text("legal.privacy.body")
        case .terms: return L10n.text("legal.terms.body")
        case .help: return L10n.text("legal.help.body")
        case .about:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
            return L10n.format("legal.about.body", version, build)
        case .sources: return L10n.text("legal.sources.body")
        case .tmdb: return L10n.text("legal.tmdb.body")
        }
    }

    var externalURL: URL {
        switch self {
        case .privacy: return ReelSpanLinks.privacy
        case .terms: return ReelSpanLinks.terms
        case .help: return ReelSpanLinks.supportEmailURL
        case .about: return ReelSpanLinks.website
        case .sources: return ReelSpanLinks.website
        case .tmdb: return ReelSpanLinks.tmdbAttribution
        }
    }

    var isLocal: Bool {
        self == .about || self == .sources
    }
}
