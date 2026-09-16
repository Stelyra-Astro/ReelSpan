import SwiftUI

/// A full-screen destination, not a bottom drawer. Submissions never edit published movies.
struct ContributionHubView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let movie: MovieViewData?

    init(movie: MovieViewData? = nil) { self.movie = movie }

    var body: some View {
        NavigationStack {
            Group {
                if let movie {
                    ContributionFormView(movieQID: movie.movieQID, movieTitle: movie.title)
                } else {
                    hub
                }
            }
            .navigationTitle(movie == nil ? "Contribute" : "Correct story details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                if movie != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink("History") { ContributionHistoryView() }
                    }
                }
            }
        }
        .task { await model.contributions.refresh() }
    }

    private var hub: some View {
        List {
            Section {
                Text("Help fill the gaps in cinema's story map. Suggestions are reviewed before appearing in the catalog.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 9) {
                    countCard("Total", model.contributions.totalCount)
                    countCard("In review", model.contributions.pendingCount)
                    countCard("Accepted", model.contributions.acceptedCount)
                    countCard("Rejected", model.contributions.rejectedCount)
                }
                NavigationLink {
                    ContributionHistoryView()
                } label: {
                    Label("My contributions and review status", systemImage: "clock.arrow.circlepath")
                }
            }
            Section("Add a film") {
                NavigationLink {
                    ContributionFormView(movieQID: nil, movieTitle: "")
                } label: {
                    Label("Add a film missing from ReelSpan", systemImage: "plus.square.on.square")
                }
                Text("Film name, story time and story place are required. TMDB, IMDb and historical tags are optional.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Complete a film") {
                missingLink("Has time, missing place", category: "time_no_place")
                missingLink("Has place, missing time", category: "place_no_time")
                missingLink("Missing both time and place", category: "neither")
            }
            if let message = model.contributions.errorMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await model.contributions.refresh() } }
            }
        }
        .refreshable { await model.contributions.refresh() }
    }

    private func countCard(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(value)").font(.headline.monospacedDigit())
            Text(title).font(.system(size: 10)).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 11)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private func missingLink(_ title: String, category: String) -> some View {
        NavigationLink {
            MissingFilmPickerView(category: category, title: title)
        } label: {
            HStack {
                Text(title)
                Spacer()
                if let count = model.contributions.missingCounts[category] {
                    Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ContributionHistoryView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            Section {
                HStack {
                    Text("\(model.contributions.totalCount) total")
                    Spacer()
                    Text("\(model.contributions.pendingCount) in review")
                }
                .font(.subheadline)
                Text("\(model.contributions.acceptedCount) accepted · \(model.contributions.rejectedCount) rejected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Submission history") {
                ForEach(model.contributions.history) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.title ?? "Story details · \(item.movie_qid ?? "Film")")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(statusLabel(item.status))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(item.status == "accepted" ? .green : item.status == "rejected" ? .red : .orange)
                        }
                        Text(item.submission_kind == "new" ? "New film" : "Time / place correction")
                            .font(.caption2).foregroundStyle(.secondary)
                        if !item.time_entries.isEmpty { Text("When: " + item.time_entries.joined(separator: " · ")) }
                        if !item.place_entries.isEmpty { Text("Where: " + item.place_entries.joined(separator: " · ")) }
                        if !item.concept_entries.isEmpty { Text("Tags: " + item.concept_entries.joined(separator: " · ")) }
                        if let note = item.moderation_note, !note.isEmpty { Text("Review note: " + note) }
                        Text(item.submitted_at, style: .date).font(.caption2).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.vertical, 5)
                }
                if model.contributions.history.isEmpty {
                    ContentUnavailableView("No contributions yet", systemImage: "square.and.pencil",
                                           description: Text("Your submissions and review decisions will appear here."))
                }
            }
        }
        .navigationTitle("My contributions")
        .refreshable { await model.contributions.refresh() }
        .task { await model.contributions.refresh() }
    }

    private func statusLabel(_ value: String) -> String {
        switch value { case "accepted": return "Accepted"; case "rejected": return "Rejected"; default: return "In review" }
    }
}

private struct MissingFilmPickerView: View {
    @EnvironmentObject private var model: AppModel
    let category: String
    let title: String
    @State private var rows: [MissingFilm] = []
    @State private var loading = false
    @State private var failed: String?
    @State private var more = true

    var body: some View {
        List {
            ForEach(rows) { movie in
                NavigationLink {
                    ContributionFormView(movieQID: movie.movie_qid, movieTitle: movie.title)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(movie.title).font(.subheadline.weight(.medium))
                        Text(movie.tmdb_id.map { "TMDB #\($0)" } ?? movie.movie_qid)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            else if more {
                Button("Load more") { Task { await loadMore() } }
            } else if rows.isEmpty {
                ContentUnavailableView("No films in this category", systemImage: "checkmark.circle",
                                       description: Text("All currently indexed films have at least one story place."))
            }
            if let failed {
                Text(failed).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await loadMore() } }
            }
        }
        .navigationTitle(title)
        .task { if rows.isEmpty { await loadMore() } }
    }

    private func loadMore() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await model.contributions.missing(category: category, offset: rows.count)
            rows.append(contentsOf: page)
            more = page.count == 30
            failed = nil
        } catch { failed = error.localizedDescription }
    }
}

private struct ContributionFormView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let movieQID: String?
    let movieTitle: String
    @State private var title = ""
    @State private var tmdbID = ""
    @State private var imdbID = ""
    @State private var times = [""]
    @State private var places = [""]
    @State private var tags = [""]
    @State private var sending = false
    @State private var error: String?
    @State private var success = false

    private var isNew: Bool { movieQID == nil }
    private var validTimes: [String] { normalized(times) }
    private var validPlaces: [String] { normalized(places) }
    private var validTags: [String] { normalized(tags) }
    private var canSubmit: Bool {
        if isNew { return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !validTimes.isEmpty && !validPlaces.isEmpty }
        return !validTimes.isEmpty || !validPlaces.isEmpty
    }

    var body: some View {
        Form {
            Section(isNew ? "Film to add" : "Film to correct") {
                if isNew {
                    TextField("Film name *", text: $title)
                    TextField("TMDB ID · optional", text: $tmdbID).keyboardType(.numberPad)
                    TextField("IMDb ID · optional (tt…)", text: $imdbID).textInputAutocapitalization(.never)
                } else {
                    Text(movieTitle).font(.headline)
                    Text("Only story time and place can be corrected here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            entriesSection("Story time", hint: "Year, range, dynasty, war or historical period", values: $times)
            entriesSection("Story place", hint: "Modern or historical place; one per entry", values: $places)
            if isNew {
                entriesSection("Historical tags · optional", hint: "Ice Age, Third Reich, a person or event", values: $tags)
            }
            Section {
                Text(isNew ? "Name, at least one time and one place are required. You may add several of each."
                           : "Only enter the time or place you want reviewed; existing data will not be overwritten automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        Spacer()
                        if sending { ProgressView() } else { Text("Send for review").fontWeight(.semibold) }
                        Spacer()
                    }
                }
                .disabled(sending || !canSubmit)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .navigationTitle(isNew ? "Add a film" : "Suggest a correction")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Contribution received", isPresented: $success) {
            Button("Done") { dismiss() }
        } message: {
            Text("Your suggestion is in review. Track its status in My contributions.")
        }
    }

    private func entriesSection(_ title: String, hint: String, values: Binding<[String]>) -> some View {
        Section(title) {
            ForEach(values.wrappedValue.indices, id: \.self) { index in
                HStack {
                    TextField(hint, text: values[index])
                        .textInputAutocapitalization(.sentences)
                    if values.wrappedValue.count > 1 {
                        Button(role: .destructive) { values.wrappedValue.remove(at: index) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if values.wrappedValue.count < 12 {
                Button { values.wrappedValue.append("") } label: {
                    Label("Add another", systemImage: "plus.circle")
                }
            }
        }
    }

    private func normalized(_ values: [String]) -> [String] {
        values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func submit() async {
        guard canSubmit else { return }
        sending = true
        defer { sending = false }
        do {
            try await model.contributions.submit(existingMovieQID: movieQID,
                                                 title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                 tmdbID: tmdbID.trimmingCharacters(in: .whitespacesAndNewlines),
                                                 imdbID: imdbID.trimmingCharacters(in: .whitespacesAndNewlines),
                                                 times: validTimes, places: validPlaces, concepts: validTags)
            error = nil
            success = true
        } catch { self.error = error.localizedDescription }
    }
}
