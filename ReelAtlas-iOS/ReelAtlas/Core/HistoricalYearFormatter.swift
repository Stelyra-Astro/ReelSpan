import Foundation

public enum HistoricalYearFormatter {
    public static func string(_ year: Int) -> String {
        year < 0 ? "\(abs(year)) BCE" : "\(year)"
    }
}
