import Foundation

/// Story-year grouping. The astronomical year 0 is 1 BCE, -99 is 100 BCE.
public struct FilmYearSpan: Hashable, Sendable {
    public let start: Int
    public let end: Int
    public init(_ start: Int, _ end: Int) {
        self.start = min(start, end)
        self.end = max(start, end)
    }
}

public enum FilmGroupRules {
    public static func merged(_ spans: [FilmYearSpan]) -> [FilmYearSpan] {
        let ordered = spans.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var result: [FilmYearSpan] = []
        for span in ordered {
            if let previous = result.last, span.start <= previous.end {
                result[result.count - 1] = FilmYearSpan(previous.start, max(previous.end, span.end))
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// Positive values are CE centuries, negative values are BCE centuries.
    public static func century(for year: Int) -> Int {
        year >= 1 ? (year - 1) / 100 + 1 : -((-year) / 100 + 1)
    }

    public static func centuries(for spans: [FilmYearSpan]) -> [Int] {
        // Some source labels (e.g. Lower Paleolithic) have speculative 600,000-year
        // bounds. They are not useful as thousands of individual century groups.
        // Prefer any more precise spans recorded for the same film.
        let ranges = merged(spans.filter { $0.end - $0.start <= 3_000 })
        var seen = Set<Int>()
        for range in ranges {
            let first = century(for: range.start), last = century(for: range.end)
            for century in first...last where century != 0 { seen.insert(century) }
        }
        return seen.sorted(by: >)
    }

    public static func hasOnlyBroadTime(_ spans: [FilmYearSpan]) -> Bool {
        !spans.isEmpty && spans.allSatisfy { $0.end - $0.start > 3_000 }
    }

    public static func centuryBounds(_ century: Int) -> FilmYearSpan {
        precondition(century != 0)
        if century > 0 { return FilmYearSpan((century - 1) * 100 + 1, century * 100) }
        return FilmYearSpan(century * 100 + 1, (century + 1) * 100)
    }

    /// Reject mistakenly catalogued exact dates and calendar centuries in 'Eras'.
    /// Year and month evidence stays in the underlying film story-time associations.
    public static func isCalendarLabel(_ label: String) -> Bool {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.range(of: #"^\d+(st|nd|rd|th) century( bc| bce)?$"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"^\d{1,5}( bc| bce| ad| ce)$"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"^\d{3,4}s$"#, options: .regularExpression) != nil { return true }
        let months = ["january", "february", "march", "april", "may", "june", "july",
                      "august", "september", "october", "november", "december"]
        return months.contains { month in
            text.range(of: #"^"# + month + #"( \d{1,2},? \d{3,4}| \d{3,4})$"#,
                       options: .regularExpression) != nil
        }
    }

    public static func centuryLabel(_ century: Int) -> String {
        let number = abs(century)
        let suffix = number % 100 >= 11 && number % 100 <= 13 ? "th" :
            (number % 10 == 1 ? "st" : number % 10 == 2 ? "nd" : number % 10 == 3 ? "rd" : "th")
        return "\(number)\(suffix) century\(century < 0 ? " BCE" : "")"
    }
}
