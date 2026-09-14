import Foundation

struct SearchRequestTracker: Sendable {
    private var latestQuery = ""

    mutating func update(_ query: String) -> String? {
        latestQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return latestQuery.count >= 2 ? latestQuery : nil
    }

    func accepts(_ query: String) -> Bool {
        query == latestQuery
    }
}

enum SearchSuggestionOrder {
    static func placesFirst<Element>(
        indexedPlaces: [Element],
        mapPlaces: [Element],
        movies: [Element]
    ) -> [Element] {
        indexedPlaces + mapPlaces + movies
    }
}

enum ResultsDrawerLevel: Equatable {
    case hidden
    case tip
    case medium
    case full
}

struct ResultsDrawerState: Equatable {
    private(set) var level: ResultsDrawerLevel = .medium
    private var keepsCollapsed = false

    mutating func searchFocused() {
        level = .hidden
    }

    mutating func searchFinished() {
        level = keepsCollapsed ? .tip : .medium
    }

    mutating func mapNavigationStarted() {
        level = .tip
        keepsCollapsed = true
    }

    mutating func mapFocusUpdated() {
        // Deliberately keep the current level so map browsing is uninterrupted.
    }

    mutating func move(to level: ResultsDrawerLevel) {
        self.level = level
    }

    mutating func userMoved(to level: ResultsDrawerLevel) {
        self.level = level
        keepsCollapsed = level == .tip
    }

    mutating func showResults() {
        keepsCollapsed = false
        level = .medium
    }
}

enum PlaceSearchSubmissionAction: Equatable {
    case dismissKeyboard
    case showCandidates
}

enum PlaceSearchSubmission {
    static func action(for query: String) -> PlaceSearchSubmissionAction {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .dismissKeyboard
            : .showCandidates
    }
}

enum MapLookupErrorPolicy {
    static func isNonFatal(domain: String, code: Int) -> Bool {
        domain == "kCLErrorDomain" && (code == 8 || code == 10)
    }

    static func isNonFatal(_ error: Error) -> Bool {
        let error = error as NSError
        return isNonFatal(domain: error.domain, code: error.code)
    }
}
