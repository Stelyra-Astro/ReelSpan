import Foundation

public enum StoryTimeMatcher {
    public static func matches(year: Int, ranges: [StoryTimeRange]) -> Bool {
        ranges.contains { year >= $0.startYear && year <= $0.endYear }
    }

    public static func matches(startYear: Int, endYear: Int, ranges: [StoryTimeRange]) -> Bool {
        ranges.contains { $0.startYear <= endYear && $0.endYear >= startYear }
    }
}

public enum StoryTimeAvailabilityMatcher {
    public static func includesUnknown(startYear: Int, endYear: Int) -> Bool {
        startYear == StoryTimeSelection.minimumYear && endYear == StoryTimeSelection.maximumYear
    }
}

public struct StoryTimeSelection: Equatable, Sendable {
    public static let minimumYear = -7000
    public static let maximumYear = 3000

    public private(set) var startYear: Int
    public private(set) var endYear: Int

    public init(startYear: Int = minimumYear, endYear: Int = maximumYear) {
        self.startYear = Self.clamped(startYear)
        self.endYear = Self.clamped(endYear)
        if self.startYear > self.endYear {
            self.endYear = self.startYear
        }
    }

    public mutating func updateStartYear(_ value: Int) {
        startYear = Self.clamped(value)
        if startYear > endYear { endYear = startYear }
    }

    public mutating func updateEndYear(_ value: Int) {
        endYear = Self.clamped(value)
        if endYear < startYear { startYear = endYear }
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, minimumYear), maximumYear)
    }
}

public enum TimeNormalizer {
    public static func contemporaryRange(releaseYear: Int) -> StoryTimeRange {
        let decade = (releaseYear / 10) * 10
        return StoryTimeRange(
            startYear: decade,
            endYear: decade + 9,
            normalizationType: "release_decade_for_contemporary",
            confidence: 0.8
        )
    }
}
