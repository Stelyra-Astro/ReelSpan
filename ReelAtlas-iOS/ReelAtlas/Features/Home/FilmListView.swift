import SwiftUI

struct FilmRetryButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button("Retry") {
            Task { await model.retryUnavailableFilms() }
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(red: 0.11, green: 0.20, blue: 0.28))
        .disabled(model.isLoadingMovies || model.isContentLoading || model.isRetryingFilms)
    }
}

/// Native adaptation of the list-mode HTML prototype. All rows come from the live catalog.
struct FilmListView: View {
    var showsMap = false
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var grouping = "all"
    @State private var selectedMovie: MovieViewData?
    @State private var correctingMovie: MovieViewData?
    @State private var showContributions = false
    @State private var showSettings = false
    @State private var showFavorites = false
    @State private var showTip = false
    @State private var showWhere = false
    @State private var showWhen = false
    @State private var showYearPicker = false
    @State private var whereQuery = ""
    @State private var selectedContinent: String?
    @State private var selectedCountryQID: String?
    @State private var whenCategory: String?
    @State private var selectedCentury: Int?
    @State private var whenQuery = ""
    @State private var yearFrom = "1900"
    @State private var yearTo = "2000"

    private let navy = Color(red: 0.11, green: 0.20, blue: 0.28)
    private let pale = Color(red: 0.93, green: 0.96, blue: 0.98)

    var body: some View {
        VStack(spacing: 0) {
            header
            if !showsMap {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.showingOfflineSamples {
                            Text("Showing saved films · Live catalog updating")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        }
                        if grouping == "all" {
                            ForEach(model.movies) { movie in filmRow(movie) }
                        } else if grouping == "place" {
                            if model.whereCatalog.isEmpty || model.movies.contains(where: { model.movieCountryQIDs[$0.movieQID] == nil }) {
                                Text("Grouping is unavailable offline. Showing saved films.")
                                    .font(.caption).foregroundStyle(.secondary).padding(12)
                                ForEach(model.movies) { movie in filmRow(movie) }
                            } else {
                                ForEach(continentGroups) { continent in
                                    HStack {
                                        Image(systemName: "globe.europe.africa")
                                        Text(continent.title).font(.system(.title3, design: .serif).bold())
                                        Spacer()
                                    }
                                    .foregroundStyle(navy).padding(.horizontal, 15).padding(.top, 20)
                                    ForEach(continent.countryGroups) { country in
                                        groupHeading(country.title, count: country.movies.count, icon: "mappin")
                                        ForEach(country.movies) { movie in filmRow(movie) }
                                    }
                                }
                            }
                        } else {
                            ForEach(groupedMovies) { group in
                                groupHeading(group.title, count: group.movies.count, icon: "calendar")
                                ForEach(group.movies) { movie in filmRow(movie) }
                            }
                        }
                        if model.isLoadingMovies {
                            ProgressView().frame(maxWidth: .infinity).padding(18)
                        } else if model.hasMoreMovies {
                            Color.clear.frame(height: 32).onAppear { model.loadMoreMovies() }
                        } else if model.movies.isEmpty && !model.isContentLoading {
                            VStack(spacing: 12) {
                            ContentUnavailableView(model.catalogSearchError == nil ? "No matching films" : "Films unavailable for now",
                                                   systemImage: "film.stack",
                                                   description: Text(model.catalogSearchError == nil
                                                       ? "Try another place, time, or search term."
                                                       : "Films will appear when this view can load."))
                            if model.catalogSearchError != nil {
                                FilmRetryButton()
                            }
                            }
                            .padding(.top, 65)
                        }
                    }
                    .padding(.horizontal, 11)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(Color(red: 0.98, green: 0.99, blue: 0.995))
            }
        }
        .background(.white)
        .fixedSize(horizontal: false, vertical: showsMap)
        .onAppear {
            search = model.globalSearch
            if model.movies.isEmpty && !model.isLoadingMovies { model.reload() }
        }
        .task(id: search) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }
            model.setGlobalSearch(search)
        }
        .onChange(of: grouping) { _, value in
            if value == "place" { Task { await model.ensureWhereCatalog(); await model.loadCountryAssociations() } }
        }
        .onChange(of: model.movies.map(\.movieQID)) { _, _ in
            if grouping == "place" { Task { await model.loadCountryAssociations() } }
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
        .fullScreenCover(item: $correctingMovie) { movie in
            ContributionHubView(movie: movie).environmentObject(model)
        }
        .fullScreenCover(isPresented: $showContributions) {
            ContributionHubView().environmentObject(model)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ReelSpan")
                        .font(.system(size: 27, weight: .bold, design: .serif))
                        .tracking(-1.1).foregroundStyle(navy)
                    Text("Cinema across time & place")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                headerIcon("square.and.pencil") { showContributions = true }
                    .accessibilityIdentifier("openContributions")
                    .accessibilityLabel("Contribute films and story details")
                headerIcon("heart") { showFavorites = true }
                headerIcon("gift") { showTip = true }
                headerIcon("gearshape") { showSettings = true }
            }
            HStack(spacing: 2) {
                modeButton("Map", symbol: "map", selected: showsMap) { model.setListMode(false) }
                modeButton("List", symbol: "list.bullet", selected: !showsMap) { model.setListMode(true) }
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
                    whereQuery = ""; selectedContinent = nil; selectedCountryQID = nil; showWhere = true
                }
                filterChip("When", value: whenLabel, symbol: "calendar") {
                    whenCategory = nil; selectedCentury = nil; whenQuery = ""; showWhen = true
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
                Text("\(max(model.syncDownloaded, model.syncTotal) > 0 ? max(model.syncDownloaded, model.syncTotal) : model.movies.count) films in the atlas")
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
            // Initial and incremental sync run in the background without technical
            // error banners, progress bars or manual retry controls.
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
        MovieRowView(movie: movie, isFavorite: model.favoriteIDs.contains(movie.id),
                     onFavorite: { model.toggleFavorite(movie.id) },
                     onContribute: { correctingMovie = movie })
        .onTapGesture { selectedMovie = movie }
        Divider().padding(.leading, 83)
    }

    private struct FilmGroup: Identifiable {
        let id: String
        let title: String
        let movies: [MovieViewData]
    }

    private struct ContinentGroup: Identifiable {
        let title: String
        let countryGroups: [FilmGroup]
        var id: String { title }
    }

    private func groupHeading(_ label: String, count: Int, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
            Text(label).font(.system(.headline, design: .serif))
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .foregroundStyle(navy).padding(.horizontal, 15).padding(.top, 15).padding(.bottom, 6)
    }

    /// Movie-country links are fetched only for the visible page. A film set in multiple
    /// countries appears once within each country and never duplicates within one country.
    private var countryGroups: [FilmGroup] {
        let countries = Dictionary(uniqueKeysWithValues: model.whereCatalog
            .filter { $0.category == "country" }.map { ($0.qid, $0) })
        var groups: [String: [MovieViewData]] = [:]
        for movie in model.movies {
            let qids = Set(model.movieCountryQIDs[movie.movieQID] ?? [])
            let supported = qids.filter { countries[$0] != nil }
            if supported.isEmpty {
                groups["unmapped", default: []].append(movie)
            } else {
                for qid in supported { groups[qid, default: []].append(movie) }
            }
        }
        return groups.map { key, films in
            FilmGroup(id: key, title: countries[key]?.name ?? "Other / Unmapped stories", movies: films)
        }
        .sorted { lhs, rhs in
            if lhs.id == "unmapped" { return false }
            if rhs.id == "unmapped" { return true }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private var continentGroups: [ContinentGroup] {
        let lookup = Dictionary(uniqueKeysWithValues: model.whereCatalog
            .filter { $0.category == "country" }.map { ($0.qid, $0.continent) })
        let grouped = Dictionary(grouping: countryGroups) { lookup[$0.id] ?? "Other locations" }
        let order = ["Africa", "Asia", "Europe", "North America", "South America", "Oceania", "Other locations"]
        return order.compactMap { name in
            guard let countries = grouped[name], !countries.isEmpty else { return nil }
            return ContinentGroup(title: name, countryGroups: countries)
        }
    }

    private var groupedMovies: [FilmGroup] {
        var grouped: [Int: [MovieViewData]] = [:]
        var undated: [MovieViewData] = []
        var broad: [MovieViewData] = []
        for movie in model.movies {
            let spans = movie.timeRanges.map { FilmYearSpan($0.startYear, $0.endYear) }
            let centuries = FilmGroupRules.centuries(for: spans)
            if centuries.isEmpty {
                if FilmGroupRules.hasOnlyBroadTime(spans) { broad.append(movie) }
                else { undated.append(movie) }
            }
            for century in centuries { grouped[century, default: []].append(movie) }
        }
        var groups = grouped.keys.sorted(by: >).map { century in
            FilmGroup(id: String(century), title: FilmGroupRules.centuryLabel(century),
                      movies: grouped[century] ?? [])
        }
        if !broad.isEmpty {
            groups.append(FilmGroup(id: "broad", title: "Broad or uncertain time", movies: broad))
        }
        if !undated.isEmpty {
            groups.append(FilmGroup(id: "undated", title: "Unspecified time", movies: undated))
        }
        return groups
    }

    private let continentOrder = ["Africa", "Asia", "Europe", "North America", "South America", "Oceania"]

    private var whereMatches: [ModernWherePlace] {
        let term = whereQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return model.whereCatalog }
        return model.whereCatalog.filter {
            $0.name.localizedCaseInsensitiveContains(term) || $0.englishName.localizedCaseInsensitiveContains(term)
        }
    }

    private var whereSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Search countries or cities", text: $whereQuery)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder).padding()
                List {
                    Button("Anywhere · All places") { model.setWherePlace(nil); showWhere = false }
                    if model.whereCatalog.isEmpty {
                        if model.isLoadingWhereCatalog {
                            ProgressView("Loading place catalog…")
                        } else {
                            Text("Place options will appear when available.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if !whereQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Section("Matching countries and cities") {
                            ForEach(whereMatches) { place in whereChoice(place) }
                            if whereMatches.isEmpty { Text("No indexed films in matching places").foregroundStyle(.secondary) }
                        }
                    } else if selectedContinent == nil {
                        Section("Continents") {
                            ForEach(continentOrder.filter { continent in
                                model.whereCatalog.contains { $0.continent == continent && $0.category == "country" }
                            }, id: \.self) { continent in
                                Button { selectedContinent = continent } label: {
                                    HStack { Text(continent); Spacer(); Image(systemName: "chevron.right") }
                                }
                            }
                        }
                    } else if selectedCountryQID == nil {
                        Section("\(selectedContinent!) · Countries") {
                            ForEach(model.whereCatalog.filter {
                                $0.category == "country" && $0.continent == selectedContinent && $0.filmCount > 0
                            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { country in
                                Button { selectedCountryQID = country.qid } label: {
                                    HStack {
                                        Text(country.name)
                                        Spacer()
                                        Text("\(country.filmCount)").foregroundStyle(.secondary).font(.caption)
                                        Image(systemName: "chevron.right")
                                    }
                                }
                            }
                        }
                    } else {
                        Section("Country and cities") {
                            if let country = model.whereCatalog.first(where: { $0.qid == selectedCountryQID }) {
                                whereChoice(country, displayName: "All of \(country.name)")
                                ForEach(model.whereCatalog.filter {
                                    $0.category == "city" && $0.countryQID == selectedCountryQID && $0.filmCount > 0
                                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { city in
                                    whereChoice(city)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Where")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !whereQuery.isEmpty {
                        Button("Clear") { whereQuery = "" }
                    } else if selectedCountryQID != nil {
                        Button("Back") { selectedCountryQID = nil }
                    } else if selectedContinent != nil {
                        Button("Back") { selectedContinent = nil }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { showWhere = false } }
            }
        }
        .task { await model.ensureWhereCatalog() }
        .presentationDetents([.large])
    }

    private func whereChoice(_ place: ModernWherePlace, displayName: String? = nil) -> some View {
        Button {
            model.setWherePlace(place)
            showWhere = false
        } label: {
            HStack {
                Image(systemName: place.category == "country" ? "globe" : "mappin")
                Text(displayName ?? place.name)
                Spacer()
                Text("\(place.filmCount)").font(.caption).foregroundStyle(.secondary)
                if model.selectedWhere?.qid == place.qid { Image(systemName: "checkmark") }
            }
        }
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
                    } else if whenCategory == "calendar" && selectedCentury == nil && whenQuery.isEmpty {
                        Section("Choose a century") {
                            ForEach(calendarCenturies, id: \.self) { century in
                                Button { selectedCentury = century } label: {
                                    HStack {
                                        Text(FilmGroupRules.centuryLabel(century))
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                    }
                                }
                            }
                        }
                    } else {
                        Section(whenCategory.flatMap { key in whenCategories.first { $0.id == key }?.title } ?? "All periods") {
                            if let century = selectedCentury, whenQuery.isEmpty {
                                Button("All films in \(FilmGroupRules.centuryLabel(century))") {
                                    let years = FilmGroupRules.centuryBounds(century)
                                    model.setStoryTimeRange(startYear: years.start, endYear: years.end)
                                    showWhen = false
                                }
                            }
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
                    if selectedCentury != nil { Button("Back") { selectedCentury = nil } }
                    else if whenCategory != nil { Button("Back") { whenCategory = nil } }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { showWhen = false } }
            }
        }
        .presentationDetents([.large])
    }

    private var calendarCenturies: [Int] {
        let spans = model.whenConcepts.filter { $0.category == "calendar" }.compactMap { concept -> FilmYearSpan? in
            guard let start = concept.startYear, let end = concept.endYear else { return nil }
            return FilmYearSpan(start, end)
        }
        return FilmGroupRules.centuries(for: spans)
    }

    private var visibleConcepts: [TimeConcept] {
        model.whenConcepts.filter { concept in
            (whenCategory == nil || concept.category == whenCategory) &&
            (whenQuery.isEmpty || concept.name.localizedCaseInsensitiveContains(whenQuery)) &&
            (whenCategory != "era" || !FilmGroupRules.isCalendarLabel(concept.name)) &&
            (selectedCentury == nil || {
                guard let start = concept.startYear, let end = concept.endYear,
                      let century = selectedCentury else { return false }
                let bounds = FilmGroupRules.centuryBounds(century)
                return start <= bounds.end && end >= bounds.start
            }())
        }
        .prefix(150)
        .map { $0 }
    }
}
