import Foundation

public enum RankingCalculator {
    public static func bayesian(rating: Double, votes: Int, globalMean: Double, minimumVotes: Int) -> Double {
        guard minimumVotes > 0 else { return rating }
        let v = Double(max(votes, 0))
        let m = Double(minimumVotes)
        return (v / (v + m)) * rating + (m / (v + m)) * globalMean
    }
}
