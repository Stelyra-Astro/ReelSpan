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
    case medium
    case full
}

/// A dismissed sheet occupies no screen area. The separate map pill remains tappable.
struct ResultsDrawerState: Equatable {
    private(set) var level: ResultsDrawerLevel = .hidden
    private var keepsCollapsed = true

    mutating func searchFocused() {
        userDismissed()
    }

    mutating func searchFinished() {
        if !keepsCollapsed { level = .medium }
    }

    mutating func mapNavigationStarted() {
        userDismissed()
    }

    mutating func mapFocusUpdated() {
        // A map camera callback must not reopen a dismissed drawer.
    }

    mutating func move(to level: ResultsDrawerLevel) {
        self.level = level
        keepsCollapsed = level == .hidden
    }

    mutating func userMoved(to level: ResultsDrawerLevel) {
        // Dragging down from the expanded sheet should close it entirely,
        // rather than parking at the smaller sheet detent.
        if self.level == .full && level == .medium {
            userDismissed()
        } else {
            move(to: level)
        }
    }

    mutating func userDismissed() {
        keepsCollapsed = true
        level = .hidden
    }

    mutating func showResults() {
        keepsCollapsed = false
        level = .medium
    }
}

/// Only an exact total may be placed next to a country or city name.
enum MapResultsLabel {
    static func text(place: String, exactCount: Int?, isPartial: Bool = false) -> String {
        guard let exactCount else { return "\(place) · Films" }
        return "\(place) · \(exactCount) \(isPartial ? "saved films" : "films")"
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
