import Foundation

enum LegalPage: String, Identifiable, Hashable {
    case privacy, terms, help, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: return L10n.text("legal.privacy.title")
        case .terms: return L10n.text("legal.terms.title")
        case .help: return L10n.text("legal.help.title")
        case .about: return L10n.text("legal.about.title")
        }
    }

    var body: String {
        switch self {
        case .privacy: return L10n.text("legal.privacy.body")
        case .terms: return L10n.text("legal.terms.body")
        case .help: return L10n.text("legal.help.body")
        case .about: return L10n.text("legal.about.body")
        }
    }

    var externalURL: URL {
        switch self {
        case .privacy: return ReelSpanLinks.privacy
        case .terms: return ReelSpanLinks.terms
        case .help: return ReelSpanLinks.supportEmailURL
        case .about: return ReelSpanLinks.website
        }
    }
}
