import SwiftUI

struct YearPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var startText: String
    @State private var endText: String
    let onSelect: (Int, Int) -> Void

    init(startYear: Int, endYear: Int, onSelect: @escaping (Int, Int) -> Void) {
        self.onSelect = onSelect
        _startText = State(initialValue: String(startYear))
        _endText = State(initialValue: String(endYear))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("year.exact") {
                    TextField(L10n.text("year.start"), text: $startText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField(L10n.text("year.end"), text: $endText)
                        .keyboardType(.numbersAndPunctuation)
                    Button("year.show") {
                        if let startYear = Int(startText), let endYear = Int(endText) {
                            onSelect(startYear, endYear)
                            dismiss()
                        }
                    }
                    .disabled(Int(startText) == nil || Int(endText) == nil)
                }
                Section("year.quick") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 10) {
                        ForEach(Array(quickRanges.enumerated()), id: \.offset) { _, range in
                            Button("\(range.start)–\(range.end)") {
                                onSelect(range.start, range.end)
                                dismiss()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("year.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var quickRanges: [(start: Int, end: Int)] {
        [(1600, 1699), (1700, 1799), (1800, 1899), (1900, 1949), (1950, 1999), (2000, 2100)]
    }
}
