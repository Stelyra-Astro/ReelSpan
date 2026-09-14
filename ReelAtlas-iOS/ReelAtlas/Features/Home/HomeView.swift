import SwiftUI
import MapKit
import UIKit

struct HomeView: View {
    private enum PendingModal {
        case yearPicker
        case settings
        case favorites
    }

    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var camera: MapCameraPosition = .automatic
    @State private var drawerState = ResultsDrawerState()
    @State private var pendingModal: PendingModal?
    @State private var showYearPicker = false
    @State private var showSettings = false
    @State private var showFavorites = false
    @State private var selectedDrawerMovie: MovieViewData?
    @State private var selectedSearchMovie: MovieViewData?
    @StateObject private var placeSearch = AdministrativePlaceSearch()
    @State private var searchIsFocused = false
    @State private var movieSearchResults: [MovieViewData] = []
    @State private var movieSearch = LatestMovieSearch()
    @State private var indexedPlaces: [MapSearchSuggestion] = []
    @State private var placeTask: Task<Void, Never>?
    @State private var movieMappingTask: Task<Void, Never>?
    @State private var isSearchExpanded = false
    @State private var isTimelineExpanded = false
    @State private var mapCenterTask: Task<Void, Never>?
    @State private var cameraSuppressionTask: Task<Void, Never>?
    @State private var suppressCameraCallbacks = false

    private let tipDetent = PresentationDetent.custom(CollapsedResultsDetent.self)
    private let defaultResultsDetent = PresentationDetent.custom(TwoMovieResultsDetent.self)

    var body: some View {
        ZStack {
            MapReader { proxy in
                Map(position: $camera) {
                    Marker(model.displayedPlaceName, coordinate: model.selectedCoordinate)
                        .tint(Color(red: 0.45, green: 0.16, blue: 0.12))
                }
                .id(model.effectiveInterfaceLanguage)
                .environment(\.locale, Locale(identifier: model.effectiveInterfaceLanguage))
                .mapStyle(.standard)
                .ignoresSafeArea()
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        guard let coordinate = proxy.convert(value.location, from: .local) else { return }
                        Task {
                            await model.selectMapCoordinate(coordinate)
                            drawerState.searchFinished()
                        }
                    }
                )
                .onMapCameraChange(frequency: .onEnd) { context in
                    if !suppressCameraCallbacks {
                        scheduleMapCenterFocus(context.region.center)
                    }
                }
                .onMapCameraChange(frequency: .continuous) { _ in
                    if !suppressCameraCallbacks {
                        mapCenterTask?.cancel()
                        drawerState.mapNavigationStarted()
                    }
                }
            }

            VStack(spacing: 8) {
                topControls
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            LinearGradient(
                colors: [
                    Color(red: 0.72, green: 0.56, blue: 0.34).opacity(0.035),
                    Color(red: 0.48, green: 0.29, blue: 0.13).opacity(0.025)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.multiply)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .onAppear { updateCamera() }
        .task {
            await model.resolveInitialLocation()
            updateCamera()
        }
        .sheet(isPresented: resultsSheetIsPresented, onDismiss: resultsSheetDidDismiss) {
            movieSheet
                .presentationDetents([tipDetent, defaultResultsDetent, .large], selection: selectedResultsDetent)
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
                .presentationBackground(.regularMaterial)
                .presentationBackgroundInteraction(.enabled(upThrough: defaultResultsDetent))
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showYearPicker, onDismiss: restoreResultsDrawer) {
            YearPickerView(
                startYear: model.storyTimeSelection.startYear,
                endYear: model.storyTimeSelection.endYear
            ) { startYear, endYear in
                model.setStoryTimeRange(startYear: startYear, endYear: endYear)
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: restoreResultsDrawer) {
            SettingsView().environmentObject(model)
        }
        .sheet(isPresented: $showFavorites, onDismiss: restoreResultsDrawer) {
            FavoritesView().environmentObject(model)
        }
        .fullScreenCover(item: $selectedSearchMovie, onDismiss: restoreResultsDrawer) { movie in
            MovieDetailView(movie: movie).environmentObject(model)
        }
        .onChange(of: movieSearch.page) { _, page in
            movieMappingTask?.cancel()
            guard let page else { movieSearchResults = []; return }
            movieMappingTask = Task {
                let results = await model.searchMovies(page.results)
                guard !Task.isCancelled else { return }
                movieSearchResults = results
            }
        }
        .onDisappear {
            movieSearch.cancel()
            placeTask?.cancel()
            movieMappingTask?.cancel()
        }
        .alert(
            L10n.text("app.name"),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button(L10n.text("common.ok"), role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var resultsSheetIsPresented: Binding<Bool> {
        Binding(
            get: { drawerState.level != .hidden },
            set: { isPresented in
                if !isPresented { drawerState.move(to: .hidden) }
            }
        )
    }

    private var selectedResultsDetent: Binding<PresentationDetent> {
        Binding(
            get: {
                switch drawerState.level {
                case .tip: tipDetent
                case .full: .large
                case .hidden, .medium: defaultResultsDetent
                }
            },
            set: { detent in
                if detent == tipDetent {
                    drawerState.userMoved(to: .tip)
                } else if detent == .large {
                    drawerState.userMoved(to: .full)
                } else {
                    drawerState.userMoved(to: .medium)
                }
            }
        )
    }

    private var topControls: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 8) {
                roundControlButton(
                    systemName: isSearchExpanded ? "xmark" : "magnifyingglass",
                    accessibilityLabel: L10n.text("home.search_place")
                ) {
                    if isSearchExpanded {
                        collapseSearch()
                    } else {
                        isTimelineExpanded = false
                        isSearchExpanded = true
                        drawerState.searchFocused()
                        scheduleMovieSearch(query)
                        DispatchQueue.main.async { searchIsFocused = true }
                    }
                }

                roundControlButton(
                    systemName: "gearshape.fill",
                    accessibilityLabel: L10n.text("settings.title")
                ) {
                    collapseSearch()
                    presentAfterHidingResults(.settings)
                }

                roundControlButton(
                    systemName: model.favoriteIDs.isEmpty ? "heart" : "heart.fill",
                    accessibilityLabel: L10n.text("favorites.title")
                ) {
                    collapseSearch()
                    presentAfterHidingResults(.favorites)
                }
            }
            .shadow(radius: 8, y: 3)

            if isSearchExpanded {
                VStack(spacing: 8) {
                    HStack {
                        DynamicReturnKeyTextField(
                            text: $query,
                            placeholder: L10n.text("home.search_place"),
                            isFocused: $searchIsFocused,
                            onSubmit: submitSearchField
                        )
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .onChange(of: query) { _, value in
                            placeSearch.update(query: value)
                            scheduleMovieSearch(value)
                        }
                        .onChange(of: searchIsFocused) { _, focused in
                            if focused { drawerState.searchFocused() }
                        }
                        if model.isSearching || movieSearch.isPending {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 48)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if !combinedSearchSuggestions.isEmpty { searchSuggestions }
                    if movieSearch.error != nil {
                        Text("Movie search is temporarily unavailable. Try again shortly.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .shadow(radius: 8, y: 3)
            } else {
                Spacer(minLength: 0)
                timelineControl
            }
        }
    }

    @ViewBuilder
    private var timelineControl: some View {
        if isTimelineExpanded {
            VStack(spacing: 4) {
                HStack {
                    Text("home.story_time")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("\(L10n.year(model.storyTimeSelection.startYear))–\(L10n.year(model.storyTimeSelection.endYear))  ▾") {
                        presentAfterHidingResults(.yearPicker)
                    }
                    .font(.subheadline.bold())
                    Button {
                        isTimelineExpanded = false
                    } label: {
                        Image(systemName: "chevron.up.circle.fill")
                            .font(.title3)
                    }
                    .foregroundStyle(.primary)
                }
                HStack {
                    Text("\(L10n.text("year.start")) \(L10n.year(model.storyTimeSelection.startYear))")
                    Spacer()
                    Text("\(L10n.text("year.end")) \(L10n.year(model.storyTimeSelection.endYear))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                StoryTimeRangeSlider(
                    startYear: Binding(
                        get: { model.storyTimeSelection.startYear },
                        set: { model.setStoryStartYear($0) }
                    ),
                    endYear: Binding(
                        get: { model.storyTimeSelection.endYear },
                        set: { model.setStoryEndYear($0) }
                    )
                )
                .frame(height: 28)

                HStack {
                    Text("1600")
                    Spacer()
                    Text("2100")
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(radius: 8, y: 3)
        } else {
            roundControlButton(
                systemName: "clock.fill",
                accessibilityLabel: L10n.text("home.story_time")
            ) {
                collapseSearch()
                isTimelineExpanded = true
            }
        }
    }

    private func roundControlButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(accessibilityLabel)
    }

    private var searchSuggestions: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(combinedSearchSuggestions.prefix(12)) { suggestion in
                    Button {
                        choose(suggestion)
                    } label: {
                        HStack(spacing: 10) {
                            if case .movie(let movie) = suggestion {
                                LocalPosterView(movie: movie, cornerRadius: 4)
                                    .frame(width: 28, height: 40).clipped()
                            } else {
                                Image(systemName: suggestion.symbolName)
                                    .foregroundStyle(Color(red: 0.45, green: 0.16, blue: 0.12))
                                    .frame(width: 24)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 48)
                }
            }
        }
        .frame(maxHeight: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(radius: 8, y: 3)
    }

    private var combinedSearchSuggestions: [UnifiedSearchSuggestion] {
        var seen = Set<String>()
        let indexedPlaces = indexedPlaces.map(UnifiedSearchSuggestion.place)
        let movies = movieSearchResults.map(UnifiedSearchSuggestion.movie)
        let mapPlaces = placeSearch.suggestions.map(UnifiedSearchSuggestion.place)
        return SearchSuggestionOrder.placesFirst(
            indexedPlaces: indexedPlaces,
            mapPlaces: mapPlaces,
            movies: movies
        ).filter { suggestion in
            seen.insert(suggestion.id).inserted
        }
    }

    private func submitSearchField() {
        switch PlaceSearchSubmission.action(for: query) {
        case .dismissKeyboard:
            placeSearch.clear()
            collapseSearch()
            drawerState.searchFinished()
        case .showCandidates:
            Task { await placeSearch.submit(query: query) }
        }
    }

    @ViewBuilder
    private var movieSheet: some View {
        if drawerState.level == .tip {
            HStack(spacing: 8) {
                Text(model.selectedLocation?.name ?? model.displayedPlaceName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(L10n.year(model.storyTimeSelection.startYear))–\(L10n.year(model.storyTimeSelection.endYear))")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .accessibilityLabel(Text("home.list_picker"))
        } else {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    if let message = model.fallbackMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Text(model.selectedLocation?.name ?? model.displayedPlaceName)
                            .font(.title3.bold())
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Picker(
                            L10n.text("home.list_picker"),
                            selection: Binding(get: { model.favoritesOnly }, set: { model.setFavoritesOnly($0) })
                        ) {
                            Text("common.all").tag(false)
                            Text("common.favorites").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 132)
                    }

                    Text("\(L10n.year(model.storyTimeSelection.startYear))–\(L10n.year(model.storyTimeSelection.endYear))")
                        .font(.subheadline.monospacedDigit().weight(.semibold))

                    Text(model.movies.isEmpty ? L10n.text("home.no_matching_movies") : L10n.text("home.match_explanation"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 10)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.movies) { movie in
                            MovieRowView(
                                movie: movie,
                                isFavorite: model.favoriteIDs.contains(movie.id)
                            ) {
                                model.toggleFavorite(movie.id)
                            }
                            .onTapGesture {
                                selectedDrawerMovie = movie
                            }
                            Divider().padding(.leading, 84)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
            }
            .fullScreenCover(item: $selectedDrawerMovie) { movie in
                MovieDetailView(movie: movie).environmentObject(model)
            }
        }
    }

    private func choose(_ suggestion: UnifiedSearchSuggestion) {
        query = suggestion.title
        placeSearch.clear()
        collapseSearch()
        switch suggestion {
        case .movie(let movie):
            drawerState.move(to: .hidden)
            selectedSearchMovie = movie
        case .place(let place):
            Task {
                await model.selectSearchSuggestion(place)
                updateCamera()
                drawerState.showResults()
            }
        }
    }

    private func presentAfterHidingResults(_ modal: PendingModal) {
        pendingModal = modal
        drawerState.move(to: .hidden)
    }

    private func resultsSheetDidDismiss() {
        guard let pendingModal else { return }
        self.pendingModal = nil
        switch pendingModal {
        case .yearPicker: showYearPicker = true
        case .settings: showSettings = true
        case .favorites: showFavorites = true
        }
    }

    private func restoreResultsDrawer() {
        drawerState.searchFinished()
    }

    private func updateCamera() {
        cameraSuppressionTask?.cancel()
        suppressCameraCallbacks = true
        camera = .region(
            MKCoordinateRegion(
                center: model.selectedCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.45, longitudeDelta: 0.45)
            )
        )
        cameraSuppressionTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            suppressCameraCallbacks = false
        }
    }

    private func collapseSearch() {
        movieSearch.cancel()
        placeTask?.cancel()
        movieMappingTask?.cancel()
        indexedPlaces = []
        movieSearchResults = []
        searchIsFocused = false
        isSearchExpanded = false
    }

    private func scheduleMovieSearch(_ value: String) {
        movieMappingTask?.cancel()
        movieSearchResults = []
        let service = model.metadataStore.service
        movieSearch.update(value) { query in
            try await service.search(query: query)
        }
        placeTask?.cancel()
        indexedPlaces = []
        placeTask = Task {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let places = await model.indexedPlaceSuggestions(value)
            guard !Task.isCancelled, query == value else { return }
            indexedPlaces = places
        }
    }

    private func scheduleMapCenterFocus(_ coordinate: CLLocationCoordinate2D) {
        guard !isSearchExpanded, !showSettings, !showYearPicker, !showFavorites else { return }
        mapCenterTask?.cancel()
        mapCenterTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await model.selectMapCoordinate(coordinate, reportErrors: false)
            drawerState.mapFocusUpdated()
        }
    }
}

private struct FavoritesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMovie: MovieViewData?

    var body: some View {
        NavigationStack {
            Group {
                if model.favoriteMovies.isEmpty {
                    ContentUnavailableView(
                        "favorites.empty.title",
                        systemImage: "heart",
                        description: Text("favorites.empty.message")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.favoriteMovies) { movie in
                                MovieRowView(movie: movie, isFavorite: true) {
                                    model.toggleFavorite(movie.id)
                                }
                                .onTapGesture {
                                    selectedMovie = movie
                                }
                                Divider().padding(.leading, 84)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 20)
                    }
                }
            }
            .navigationTitle("favorites.title")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done") { dismiss() }
                }
            }
            .fullScreenCover(item: $selectedMovie) { movie in
                MovieDetailView(movie: movie).environmentObject(model)
            }
        }
    }
}

private struct CollapsedResultsDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        context.maxDetentValue * 0.11
    }
}

private struct TwoMovieResultsDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        context.maxDetentValue * 0.56
    }
}

private struct StoryTimeRangeSlider: View {
    private enum ActiveThumb {
        case start
        case end
    }

    @Binding var startYear: Int
    @Binding var endYear: Int
    @State private var activeThumb: ActiveThumb?

    private let thumbDiameter: CGFloat = 24
    private let tint = Color(red: 0.45, green: 0.16, blue: 0.12)

    var body: some View {
        GeometryReader { proxy in
            let startX = xPosition(for: startYear, width: proxy.size.width)
            let endX = xPosition(for: endYear, width: proxy.size.width)
            let centerY = proxy.size.height / 2

            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(height: 4)
                    .padding(.horizontal, thumbDiameter / 2)

                Capsule()
                    .fill(tint)
                    .frame(width: max(4, endX - startX), height: 4)
                    .position(x: (startX + endX) / 2, y: centerY)

                rangeThumb(at: startX, centerY: centerY, label: L10n.text("year.start"))

                rangeThumb(at: endX, centerY: centerY, label: L10n.text("year.end"))
            }
            .contentShape(Rectangle())
            .gesture(rangeDragGesture(width: proxy.size.width))
        }
    }

    private func rangeThumb(at x: CGFloat, centerY: CGFloat, label: String) -> some View {
        Circle()
            .fill(.background)
            .stroke(tint, lineWidth: 3)
            .frame(width: thumbDiameter, height: thumbDiameter)
            .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
            .position(x: x, y: centerY)
            .accessibilityLabel(label)
    }

    private func xPosition(for year: Int, width: CGFloat) -> CGFloat {
        let usableWidth = max(1, width - thumbDiameter)
        let progress = CGFloat(year - StoryTimeSelection.minimumYear)
            / CGFloat(StoryTimeSelection.maximumYear - StoryTimeSelection.minimumYear)
        return thumbDiameter / 2 + usableWidth * progress
    }

    private func year(at x: CGFloat, width: CGFloat) -> Int {
        let usableWidth = max(1, width - thumbDiameter)
        let progress = min(max((x - thumbDiameter / 2) / usableWidth, 0), 1)
        let span = StoryTimeSelection.maximumYear - StoryTimeSelection.minimumYear
        return StoryTimeSelection.minimumYear + Int((progress * CGFloat(span)).rounded())
    }

    private func rangeDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let proposedYear = year(at: value.location.x, width: width)
                if activeThumb == nil {
                    let startDistance = abs(proposedYear - startYear)
                    let endDistance = abs(proposedYear - endYear)
                    if startDistance == endDistance {
                        guard value.translation.width != 0 else { return }
                        activeThumb = value.translation.width < 0 ? .start : .end
                    } else {
                        activeThumb = startDistance < endDistance ? .start : .end
                    }
                }

                switch activeThumb {
                case .start:
                    startYear = min(proposedYear, endYear)
                case .end:
                    endYear = max(proposedYear, startYear)
                case nil:
                    break
                }
            }
            .onEnded { _ in activeThumb = nil }
    }
}

private enum UnifiedSearchSuggestion: Identifiable {
    case movie(MovieViewData)
    case place(MapSearchSuggestion)

    var id: String {
        switch self {
        case .movie(let movie): return "movie|\(movie.movieQID)"
        case .place(let place): return "place|\(place.id)"
        }
    }

    var title: String {
        switch self {
        case .movie(let movie): return movie.title
        case .place(let place): return place.title
        }
    }

    var subtitle: String {
        switch self {
        case .movie(let movie):
            let details = [movie.releaseYearText, movie.director].compactMap { $0 }.filter { $0 != "—" }
            return ([L10n.text("search.result.movie")] + details).joined(separator: " · ")
        case .place(let place):
            return [L10n.text("search.result.place"), place.subtitle]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
    }

    var symbolName: String {
        switch self {
        case .movie: return "film"
        case .place: return "mappin.and.ellipse"
        }
    }
}

private struct DynamicReturnKeyTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @Binding var isFocused: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: .zero)
        field.delegate = context.coordinator
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .search
        field.clearButtonMode = .whileEditing
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        // Marked text and cursor are owned by UIKit while the user is composing.
        if field.markedTextRange == nil, field.text != text {
            let selection = field.selectedTextRange
            field.text = text
            if let selection { field.selectedTextRange = selection }
        }
        field.placeholder = placeholder

        if isFocused, !field.isFirstResponder {
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                guard coordinator.parent.isFocused else { return }
                field.becomeFirstResponder()
            }
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: DynamicReturnKeyTextField

        init(parent: DynamicReturnKeyTextField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.isFocused = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isFocused = false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            let action = PlaceSearchSubmission.action(for: textField.text ?? "")
            parent.onSubmit()
            if action == .dismissKeyboard { textField.resignFirstResponder() }
            return false
        }
    }
}
