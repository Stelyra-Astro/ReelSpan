import Foundation

public enum RankingCalculator {
    public static let reelSpanGlobalMean = 6.5
    public static let reelSpanMinimumVotes = 500

    public static func bayesian(rating: Double, votes: Int, globalMean: Double, minimumVotes: Int) -> Double {
        guard minimumVotes > 0 else { return rating }
        let v = Double(max(votes, 0))
        let m = Double(minimumVotes)
        return (v / (v + m)) * rating + (m / (v + m)) * globalMean
    }

    public static func reelSpanScore(rating: Double, votes: Int) -> Double {
        bayesian(
            rating: rating,
            votes: votes,
            globalMean: reelSpanGlobalMean,
            minimumVotes: reelSpanMinimumVotes
        )
    }
}

public struct MovieRankingCandidate: Equatable, Sendable {
    public let localID: Int
    public let tmdbID: Int?
    public let hasStoryTime: Bool

    public init(localID: Int, tmdbID: Int?, hasStoryTime: Bool = true) {
        self.localID = localID
        self.tmdbID = tmdbID
        self.hasStoryTime = hasStoryTime
    }
}

public enum MovieRankingPolicy {
    public static func sortedCandidates(
        _ candidates: [MovieRankingCandidate],
        rankings: [MovieRanking]
    ) -> [MovieRankingCandidate] {
        let byTMDB = Dictionary(uniqueKeysWithValues: rankings.map { ($0.tmdbID, $0) })
        return candidates.sorted { lhs, rhs in
            if lhs.hasStoryTime != rhs.hasStoryTime { return lhs.hasStoryTime }
            let left = lhs.tmdbID.flatMap { byTMDB[$0] }
            let right = rhs.tmdbID.flatMap { byTMDB[$0] }
            switch (left, right) {
            case let (l?, r?):
                if l.score != r.score { return l.score > r.score }
                if l.voteCount != r.voteCount { return l.voteCount > r.voteCount }
                return lhs.localID < rhs.localID
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.localID < rhs.localID
            }
        }
    }
}

public enum MovieRankingBatchPolicy {
    public static func batches(_ ids: [Int], maximumBatchSize: Int = 250) -> [[Int]] {
        guard maximumBatchSize > 0 else { return [] }
        return stride(from: 0, to: ids.count, by: maximumBatchSize).map { start in
            Array(ids[start ..< min(ids.count, start + maximumBatchSize)])
        }
    }
}

public enum MovieSearchPolicy {
    public static func knownStoryMovies(
        _ items: [MovieSearchItem],
        allowedTMDBIDs: Set<Int>
    ) -> [MovieSearchItem] {
        items.filter { allowedTMDBIDs.contains($0.id) }
    }
}
