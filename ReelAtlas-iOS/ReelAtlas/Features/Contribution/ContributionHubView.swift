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
                .accessibilityIdentifier("addMissingFilm")
                Text("Film name, story time and story place are required. TMDB, IMDb and historical tags are optional.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Complete a film") {
                missingLink("Has time, missing place", category: "time_no_place")
                missingLink("Has place, missing time", category: "place_no_time")
                missingLink("Missing both time and place", category: "neither")
            }
            if let message = model.contributions.missingCountsError { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let message = model.contributions.errorMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await model.contributions.refresh() } }
            }
        }
        .refreshable { await model.contributions.refresh() }
        .onAppear { Task { await model.contributions.refreshMissingCounts() } }
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
                if model.contributions.missingCountsError == nil, let count = model.contributions.missingCounts[category] {
                    Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("missing-" + category)
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
    @State private var search = ""
    @State private var loading = false
    @State private var failed: String?
    @State private var more = true
    @State private var generation = UUID()
    @State private var selectedMovie: MovieViewData?
    @State private var correctingMovie: MovieViewData?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    let movie = row.movieData(language: model.effectiveLanguage)
                    MovieRowView(movie: movie, isFavorite: model.favoriteIDs.contains(movie.id), onFavorite: {
                        model.toggleFavorite(movie.id)
                    }, onContribute: { correctingMovie = movie })
                    .onTapGesture { selectedMovie = movie }
                    Divider().padding(.leading, 84)
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding(24) }
                else if let failed {
                    Text(failed).font(.caption).foregroundStyle(.secondary).padding()
                    Button("Retry") { Task { await loadMore() } }.padding()
                } else if more {
                    Color.clear.frame(height: 44).onAppear { Task { await loadMore() } }
                } else if rows.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No films in this category" : "No matching films",
                        systemImage: search.isEmpty ? "checkmark.circle" : "magnifyingglass",
                        description: Text(search.isEmpty ? "The live catalog has no films with these missing story details." : "Try another title, TMDB ID or IMDb ID."))
                        .padding(.top, 45)
                }
            }.padding(.horizontal, 15)
        }
        .navigationTitle(title)
        .searchable(text: $search, prompt: "Search films, TMDB or IMDb ID")
        .scrollDismissesKeyboard(.interactively)
        .task(id: search) {
            generation = UUID(); rows = []; more = true; failed = nil; loading = false
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }
            await loadMore(); await model.contributions.refreshMissingCounts()
        }
        .refreshable {
            generation = UUID(); rows = []; more = true; failed = nil; loading = false
            await loadMore(); await model.contributions.refreshMissingCounts()
        }
        .fullScreenCover(item: $selectedMovie) { movie in MovieDetailView(movie: movie).environmentObject(model) }
        .fullScreenCover(item: $correctingMovie) { movie in ContributionHubView(movie: movie).environmentObject(model) }
    }

    private func loadMore() async {
        guard !loading, more else { return }
        let requestGeneration = generation
        let query = search
        loading = true
        defer { if generation == requestGeneration { loading = false } }
        do {
            let page = try await model.contributions.missing(category: category, query: query, offset: rows.count)
            guard !Task.isCancelled, generation == requestGeneration, query == search else { return }
            let existing = Set(rows.map(\.id))
            rows.append(contentsOf: page.filter { !existing.contains($0.id) })
            more = page.count == 30; failed = nil
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            failed = error.localizedDescription
        }
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
    @State private var times = [ContributionTimeRange()]
    @State private var places = [""]
    @State private var tags = [""]
    @State private var sending = false
    @State private var error: String?
    @State private var success = false
    @State private var existingFilms: [MovieViewData] = []
    @State private var checkingExisting = false
    @State private var duplicateCheckFailed: String?
    @State private var checkedIdentity: String?
    @State private var correctingExisting: MovieViewData?
    @State private var confirmedDifferentFilm = false

    private var isNew: Bool { movieQID == nil }
    private var identity: String { [title,tmdbID,imdbID].joined(separator: "\n") }
    private var validTimes: [String] { times.compactMap(\.entry) }
    private var invalidTimeRange: Bool { times.contains { !$0.isEmpty && $0.entry == nil } }
    private var validPlaces: [String] { normalized(places) }
    private var validTags: [String] { normalized(tags) }
    private var exactDuplicate: MovieViewData? {
        existingFilms.first { ContributionDuplicatePolicy.isExisting(title: title, tmdbID: tmdbID, imdbID: imdbID,
            candidateTitle: $0.title, candidateTMDBID: $0.tmdbID, candidateIMDbID: $0.imdbID, candidateOriginalTitle: $0.catalogOriginalTitle) }
    }
    private var canSubmit: Bool {
        guard !invalidTimeRange else { return false }
        if isNew {
            return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !validTimes.isEmpty && !validPlaces.isEmpty
                && checkedIdentity == identity && !checkingExisting && duplicateCheckFailed == nil && exactDuplicate == nil
                && (existingFilms.isEmpty || confirmedDifferentFilm)
        }
        return !validTimes.isEmpty || !validPlaces.isEmpty
    }

    var body: some View {
        Form {
            Section(isNew ? "Film to add" : "Film to correct") {
                if isNew {
                    TextField("Film name *", text: $title).accessibilityIdentifier("new-film-title")
                    TextField("TMDB ID · optional", text: $tmdbID).accessibilityIdentifier("new-film-tmdb").keyboardType(.numberPad)
                    TextField("IMDb ID · optional (tt…)", text: $imdbID).accessibilityIdentifier("new-film-imdb").textInputAutocapitalization(.never)
                } else {
                    Text(movieTitle).font(.headline)
                    Text("Only story time and place can be corrected here.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if isNew { existingCatalogSection }
            timeSection
            entriesSection("Story place", hint: "Modern or historical place; one per entry", values: $places)
            if isNew { entriesSection("Historical tags · optional", hint: "Ice Age, Third Reich, a person or event", values: $tags) }
            Section {
                Text(isNew ? "Name, at least one time range and one place are required. You may add several of each."
                    : "Only enter the time or place you want reviewed; existing data will not be overwritten automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { Task { await submit() } } label: {
                    HStack {
                        Spacer()
                        if sending { ProgressView() } else { Text("Send for review").fontWeight(.semibold) }
                        Spacer()
                    }
                }.disabled(sending || !canSubmit)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .navigationTitle(isNew ? "Add a film" : "Suggest a correction")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: identity) {
            guard isNew else { return }
            checkedIdentity = nil; existingFilms = []; confirmedDifferentFilm = false
            checkingExisting = true; duplicateCheckFailed = nil
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled else { return }
            await checkExisting(identity: identity)
        }
        .fullScreenCover(item: $correctingExisting) { movie in ContributionHubView(movie: movie).environmentObject(model) }
        .alert("Contribution received", isPresented: $success) {
            Button("Done") { dismiss() }
        } message: { Text("Your suggestion is in review. Track its status in My contributions.") }
    }

    private var existingCatalogSection: some View {
        Section("Check the existing catalog") {
            if checkingExisting { ProgressView("Checking for existing films…") }
            if let duplicateCheckFailed {
                Text(duplicateCheckFailed).font(.caption).foregroundStyle(.red)
                Button("Retry check") { Task { await checkExisting(identity: identity) } }
            }
            if !existingFilms.isEmpty {
                Text(exactDuplicate == nil ? "Similar titles already exist. Select a film to correct it, or confirm this is a different film."
                    : "This film already exists. Use its edit button to correct story details.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(existingFilms) { movie in
                    MovieRowView(movie: movie, isFavorite: model.favoriteIDs.contains(movie.id), onFavorite: {
                        model.toggleFavorite(movie.id)
                    }, onContribute: { correctingExisting = movie })
                }
                if exactDuplicate == nil { Toggle("This is a different film", isOn: $confirmedDifferentFilm) }
            } else if checkedIdentity == identity && duplicateCheckFailed == nil {
                Text("No existing film found for these details.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var timeSection: some View {
        Section("Story time") {
            ForEach($times) { $range in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Start year").font(.caption).foregroundStyle(.secondary)
                            TextField("e.g. 1900", text: $range.start).accessibilityIdentifier("start-year").keyboardType(.numbersAndPunctuation)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("End year").font(.caption).foregroundStyle(.secondary)
                            TextField("e.g. 1950", text: $range.end).accessibilityIdentifier("end-year").keyboardType(.numbersAndPunctuation)
                        }
                        if times.count > 1 {
                            Button(role: .destructive) { times.removeAll { $0.id == range.id } } label: {
                                Image(systemName: "minus.circle").frame(width: 44, height: 44)
                            }.buttonStyle(.borderless)
                        }
                    }
                    if !range.isEmpty && range.entry == nil {
                        Text("Enter both years; end must be the same as or later than start.").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            if times.count < 12 {
                Button { times.append(ContributionTimeRange()) } label: { Label("Add another time range", systemImage: "plus.circle") }
            }
            Text("Use negative years for BCE. For a single year, enter the same year in both fields.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func entriesSection(_ title: String, hint: String, values: Binding<[String]>) -> some View {
        Section(title) {
            ForEach(values.wrappedValue.indices, id: \.self) { index in
                HStack {
                    TextField(hint, text: values[index]).textInputAutocapitalization(.sentences)
                    if values.wrappedValue.count > 1 {
                        Button(role: .destructive) { values.wrappedValue.remove(at: index) } label: {
                            Image(systemName: "minus.circle").frame(width: 44, height: 44)
                        }.buttonStyle(.borderless)
                    }
                }
            }
            if values.wrappedValue.count < 12 {
                Button { values.wrappedValue.append("") } label: { Label("Add another", systemImage: "plus.circle") }
            }
        }
    }
    private func normalized(_ values: [String]) -> [String] {
        values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private func checkExisting(identity requestIdentity: String) async {
        checkingExisting = true
        defer { if identity == requestIdentity { checkingExisting = false } }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tmdbID.isEmpty || !imdbID.isEmpty else { return }
        do {
            let matches = try await model.contributions.existingFilms(title: title, tmdbID: tmdbID, imdbID: imdbID)
            guard !Task.isCancelled, identity == requestIdentity else { return }
            existingFilms = matches; checkedIdentity = requestIdentity; duplicateCheckFailed = nil
        } catch {
            guard !Task.isCancelled, identity == requestIdentity else { return }
            duplicateCheckFailed = "Could not check the catalog. Retry before submitting."
        }
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
            error = nil; success = true
        } catch { self.error = error.localizedDescription }
    }
}
