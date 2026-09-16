import SwiftUI

/// Native adaptation of the list-mode HTML prototype. All rows come from the live catalog.
struct FilmListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var grouping = "all"
    @State private var selectedMovie: MovieViewData?
    @State private var showSettings = false
    @State private var showFavorites = false
    @State private var showTip = false
    @State private var showWhere = false
    @State private var showWhen = false
    @State private var showYearPicker = false
    @State private var whereQuery = ""
    @State private var whereResults: [ModernWherePlace] = []
    @State private var whenCategory: String?
    @State private var whenQuery = ""
    @State private var yearFrom = "1900"
    @State private var yearTo = "2000"

    private let navy = Color(red: 0.11, green: 0.20, blue: 0.28)
    private let pale = Color(red: 0.93, green: 0.96, blue: 0.98)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if grouping == "all" {
                        ForEach(model.movies) { movie in filmRow(movie) }
                    } else {
                        ForEach(groupedMovies) { group in
                            HStack {
                                Image(systemName: grouping == "place" ? "mappin" : "calendar")
                                Text(group.title).font(.system(.headline, design: .serif))
                                Text("\(group.movies.count)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .foregroundStyle(navy)
                            .padding(.horizontal, 15).padding(.top, 18).padding(.bottom, 6)
                            ForEach(group.movies) { movie in filmRow(movie) }
                        }
                    }
                    if model.isLoadingMovies {
                        ProgressView().frame(maxWidth: .infinity).padding(18)
                    } else if model.hasMoreMovies {
                        Color.clear.frame(height: 32).onAppear { model.loadMoreMovies() }
                    } else if model.movies.isEmpty && !model.isContentLoading {
                        ContentUnavailableView("No matching films", systemImage: "film.stack",
                                               description: Text("Try another place, time, or search term."))
                            .padding(.top, 65)
                    }
                    if let issue = model.catalogSearchError {
                        Text(issue).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(12)
                        Button("Retry full catalog") { model.reload() }
                            .font(.caption).padding(.bottom, 20)
                    }
                }
                .padding(.horizontal, 11)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(red: 0.98, green: 0.99, blue: 0.995))
        }
        .background(.white)
        .onAppear {
            search = model.globalSearch
            model.reload()
        }
        .task(id: search) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }
            model.setGlobalSearch(search)
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
        .sheet(isPresented: $showFavorites) { FavoritesView().environmentObject(model) }
        .sheet(isPresented: $showTip) { TipSheet(manager: model.tipManager) }
        .sheet(isPresented: $showWhere) { whereSheet }
        .sheet(isPresented: $showWhen) { whenSheet }
        .sheet(isPresented: $showYearPicker) {
            YearPickerView(startYear: model.storyTimeSelection.startYear,
                           endYear: model.storyTimeSelection.endYear) { a, b in
                model.setStoryTimeRange(startYear: a, endYear: b)
            }
        }
        .fullScreenCover(item: $selectedMovie) { movie in
            MovieDetailView(movie: movie).environmentObject(model)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reel Atlas")
                        .font(.system(size: 27, weight: .bold, design: .serif))
                        .tracking(-1.1).foregroundStyle(navy)
                    Text("Cinema across time & place")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                headerIcon("heart") { showFavorites = true }
                headerIcon("gift") { showTip = true }
                headerIcon("gearshape") { showSettings = true }
            }
            HStack(spacing: 2) {
                modeButton("List", symbol: "list.bullet", selected: true) { }
                modeButton("Map", symbol: "map", selected: false) { model.setListMode(false) }
            }
            .padding(3).background(pale, in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search films, people, eras, places…", text: $search)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { model.setGlobalSearch(search) }
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12).frame(height: 39)
            .background(pale, in: RoundedRectangle(cornerRadius: 11))
            HStack(spacing: 5) {
                filterChip("Where", value: model.selectedWhere?.name, symbol: "mappin") {
                    whereQuery = ""; showWhere = true
                }
                filterChip("When", value: whenLabel, symbol: "calendar") {
                    whenCategory = nil; whenQuery = ""; showWhen = true
                }
                Menu {
                    Button("All genres") { model.setGenre(nil) }
                    ForEach(["Action", "Adventure", "Animation", "Comedy", "Crime", "Documentary",
                             "Drama", "Family", "Fantasy", "History", "Horror", "Mystery", "Romance",
                             "Science Fiction", "Thriller", "War", "Western"], id: \.self) { genre in
                        Button(genre) { model.setGenre(genre) }
                    }
                } label: { filterLabel(model.selectedGenre ?? "Genre", symbol: "film", active: model.selectedGenre != nil) }
                Menu {
                    Button("Recommended") { model.setSort("recommended") }
                    Button("Newest") { model.setSort("newest") }
                    Button("Oldest") { model.setSort("oldest") }
                    Button("Title") { model.setSort("title") }
                } label: { filterLabel("Sort", symbol: "arrow.up.arrow.down", active: model.selectedSort != "recommended") }
            }
            HStack(spacing: 6) {
                Text("\(model.syncTotal > 0 ? model.syncTotal : model.movies.count) films in the atlas")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("All films") { grouping = "all" }
                    Button("Group by place") { grouping = "place" }
                    Button("Group by time") { grouping = "time" }
                } label: {
                    Label(grouping == "all" ? "All films" : "Grouped", systemImage: "square.grid.2x2")
                        .font(.caption2).foregroundStyle(navy)
                }
                Button("Reset") {
                    search = ""
                    model.setWherePlace(nil)
                    model.setWhenConcept(nil)
                    model.setGenre(nil)
                    model.setSort("recommended")
                    grouping = "all"
                }
                .font(.caption2)
            }
            if !model.syncComplete && model.syncTotal > 0 {
                HStack(spacing: 6) {
                    ProgressView(value: Double(model.syncDownloaded), total: Double(model.syncTotal))
                    Text("\(model.syncDownloaded)/\(model.syncTotal) cached")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Downloading offline catalog")
            }
        }
        .padding(.horizontal, 15).padding(.top, 6).padding(.bottom, 10)
        .background(.white)
    }

    private var whenLabel: String? {
        if let concept = model.selectedWhen { return concept.name }
        let s = model.storyTimeSelection
        if StoryTimeAvailabilityMatcher.includesUnknown(startYear: s.startYear, endYear: s.endYear) { return nil }
        return "\(s.startYear)–\(s.endYear)"
    }

    private func headerIcon(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 17)).frame(width: 30, height: 34) }
            .foregroundStyle(navy)
    }

    private func modeButton(_ label: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity).frame(height: 30)
                .foregroundStyle(selected ? .white : navy)
                .background(selected ? navy : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func filterChip(_ fallback: String, value: String?, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { filterLabel(value ?? fallback, symbol: symbol, active: value != nil) }
            .buttonStyle(.plain)
    }

    private func filterLabel(_ value: String, symbol: String, active: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(value).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8))
        }
        .font(.system(size: 11, weight: active ? .semibold : .regular))
        .foregroundStyle(active ? navy : .primary)
        .padding(.horizontal, 7).frame(height: 30)
        .background(active ? pale : .white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.90, green: 0.93, blue: 0.95)))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func filmRow(_ movie: MovieViewData) -> some View {
        MovieRowView(movie: movie, isFavorite: model.favoriteIDs.contains(movie.id)) {
            model.toggleFavorite(movie.id)
        }
        .onTapGesture { selectedMovie = movie }
        Divider().padding(.leading, 83)
    }

    private struct FilmGroup: Identifiable {
        let title: String
        let movies: [MovieViewData]
        var id: String { title }
    }

    private var groupedMovies: [FilmGroup] {
        let groups = Dictionary(grouping: model.movies) { movie in
            if grouping == "place" { return movie.locations.first?.name ?? "Unspecified place" }
            return movie.timeRanges.first?.displayText ?? "Unspecified time"
        }
        return groups.keys.sorted().map { FilmGroup(title: $0, movies: groups[$0] ?? []) }
    }

    private var whereSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Search modern countries, states, cities", text: $whereQuery)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder).padding()
                List {
                    Button("Anywhere · All places") { model.setWherePlace(nil); showWhere = false }
                    ForEach(whereResults) { place in
                        Button {
                            model.setWherePlace(place)
                            showWhere = false
                        } label: {
                            HStack {
                                Image(systemName: place.category == "country" ? "globe" : "mappin")
                                Text(place.name)
                                Spacer()
                                if model.selectedWhere?.qid == place.qid { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Where")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showWhere = false } } }
            .task(id: whereQuery) {
                if !whereQuery.isEmpty {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
                let choices = await model.findModernPlaces(whereQuery)
                guard !Task.isCancelled else { return }
                whereResults = choices
            }
        }
        .presentationDetents([.large])
    }

    private struct WhenCategory: Identifiable {
        let id: String
        let title: String
    }

    private let whenCategories: [WhenCategory] = [
        .init(id: "calendar", title: "Years & decades"),
        .init(id: "person", title: "People"),
        .init(id: "event", title: "Historical events"),
        .init(id: "regime", title: "Dynasties & states"),
        .init(id: "era", title: "Eras & movements")
    ]

    private var whenSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Search people, wars, dynasties, periods", text: $whenQuery)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder).padding()
                List {
                    Button("Any story time") {
                        model.setWhenConcept(nil)
                        showWhen = false
                    }
                    if whenCategory == nil && whenQuery.isEmpty {
                        Section("Browse by category") {
                            ForEach(whenCategories) { category in
                                Button { whenCategory = category.id } label: {
                                    HStack {
                                        Text(category.title)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                    }
                                }
                            }
                        }
                    } else {
                        Section(whenCategory.flatMap { key in whenCategories.first { $0.id == key }?.title } ?? "All periods") {
                            ForEach(visibleConcepts) { concept in
                                Button {
                                    model.setWhenConcept(concept)
                                    showWhen = false
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(concept.name)
                                        if let first = concept.startYear, let last = concept.endYear {
                                            Text("\(first) – \(last)")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            if visibleConcepts.isEmpty {
                                Text("No indexed concepts in this category yet.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Custom years") {
                        HStack {
                            TextField("From", text: $yearFrom).keyboardType(.numbersAndPunctuation)
                            Text("–")
                            TextField("To", text: $yearTo).keyboardType(.numbersAndPunctuation)
                        }
                        Button("Apply year range") {
                            guard let first = Int(yearFrom), let last = Int(yearTo), first <= last else { return }
                            model.setStoryTimeRange(startYear: first, endYear: last)
                            showWhen = false
                        }
                        .disabled(Int(yearFrom) == nil || Int(yearTo) == nil ||
                                  (Int(yearFrom) ?? 0) > (Int(yearTo) ?? 0))
                    }
                }
            }
            .navigationTitle("When")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if whenCategory != nil { Button("Back") { whenCategory = nil } }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { showWhen = false } }
            }
        }
        .presentationDetents([.large])
    }

    private var visibleConcepts: [TimeConcept] {
        model.whenConcepts.filter { concept in
            (whenCategory == nil || concept.category == whenCategory) &&
            (whenQuery.isEmpty || concept.name.localizedCaseInsensitiveContains(whenQuery))
        }
        .prefix(150)
        .map { $0 }
    }
}
