import SwiftUI

struct MovieDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private let originalMovie: MovieViewData
    @State private var showsTip = false
    private var movie: MovieViewData {
        guard let id = originalMovie.tmdbID,
              let metadata = model.metadataStore.metadataState(for: id).metadata else { return originalMovie }
        return originalMovie.enriching(with: metadata)
    }

    init(movie: MovieViewData) { self.originalMovie = movie }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    heroAndSummary

                    if let id = originalMovie.tmdbID {
                        switch model.metadataStore.metadataState(for: id) {
                        case .idle, .loading:
                            ProgressView("Loading movie details…").font(.caption).padding(8)
                        case .failed:
                            Text("Movie details are temporarily unavailable. Story information is still available.")
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                        case .loaded: EmptyView()
                        }
                    }

                    FlowTags(tags: movie.genres.isEmpty
                        ? [L10n.text("movie.genre.unknown")]
                        : Array(movie.genres.prefix(4)).map(GenreLocalization.displayName)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)

                    Divider()

                    detailSection(L10n.text("movie.overview")) {
                        Text(movie.overview.isEmpty ? L10n.text("movie.overview.unavailable") : movie.overview)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    detailSection(L10n.text("movie.story")) {
                        HStack(spacing: 10) {
                            storyCard(
                                title: L10n.text("movie.time"),
                                value: movie.storyTimeText.isEmpty ? L10n.text("movie.time.unknown") : movie.storyTimeText
                            )
                            storyCard(
                                title: L10n.text("movie.locations"),
                                value: L10n.storyLocation(movie.storyLocationText)
                            )
                        }

                        if !movie.locations.isEmpty {
                            Text(movie.locations.map(\.name).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    detailSection(L10n.text("movie.director")) {
                        Text(movie.director ?? "—")
                            .fontWeight(.semibold)
                            .foregroundStyle(movie.director == nil ? .secondary : .primary)
                    }

                    detailSection("Cast") {
                        if movie.cast.isEmpty {
                            Text("—").foregroundStyle(.secondary)
                        } else {
                            ScrollView(.horizontal) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(movie.cast) { CastMemberCard(member: $0) }
                                }
                            }
                        }
                    }

                    detailSection(L10n.text("movie.details"), showsDivider: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            detailLine(L10n.text("movie.release"), movie.releaseDate ?? movie.releaseYearText)
                            detailLine(L10n.text("movie.runtime"), L10n.runtime(movie.runtimeMinutes))
                            detailLine(L10n.text("movie.original_language"), displayLanguageName(movie.originalLanguage))
                            detailLine(
                                L10n.text("movie.countries"),
                                movie.originCountries.isEmpty ? "—" : movie.originCountries.joined(separator: " · ")
                            )
                        }
                    }
                }
            }
            .background(Color(.systemBackground))
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            }
        }
        .onAppear { if let id = originalMovie.tmdbID { model.metadataStore.beginDetail(id) } }
        .onDisappear { if let id = originalMovie.tmdbID { model.metadataStore.endDetail(id) } }
        .sheet(isPresented: $showsTip) { TipSheet(manager: model.tipManager) }
    }

    private var heroAndSummary: some View {
        HStack(alignment: .top, spacing: 14) {
            poster
                .frame(width: 104, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                Text(movie.title)
                    .font(.title2.bold())
                    .lineLimit(3)

                Text("\(movie.releaseYearText) · \(L10n.runtime(movie.runtimeMinutes))")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)

                Button { model.toggleFavorite(movie.id) } label: {
                    Label(
                        model.favoriteIDs.contains(movie.id)
                            ? L10n.text("movie.favorite.added")
                            : L10n.text("movie.favorite.add"),
                        systemImage: model.favoriteIDs.contains(movie.id) ? "heart.fill" : "heart"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(movie.id <= 0)

                Button { showsTip = true } label: { Label("Tip", systemImage: "gift") }
                    .font(.caption)
                    .buttonStyle(.borderless)

                Link(destination: movie.imdbURL) {
                    Label("IMDb", systemImage: "arrow.up.right.square")
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var poster: some View {
        LocalPosterView(movie: movie, cornerRadius: 14, isDetail: true)
    }

    private func detailSection<Content: View>(
        _ title: String,
        showsDivider: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 16)

            if showsDivider { Divider() }
        }
    }

    private func storyCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.bold())
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func detailLine(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }

    private func displayLanguageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: LanguageResolver.normalizedCode(code)) ?? code
    }
}

private struct CastMemberCard: View {
    let member: MovieCastMember

    var body: some View {
        VStack(spacing: 7) {
            avatar
                .frame(width: 60, height: 60)
                .clipShape(Circle())

            Text(member.name)
                .font(.caption.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 78, height: 32, alignment: .top)

            Text(member.character?.isEmpty == false ? member.character! : " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 78, height: 28, alignment: .top)
        }
        .frame(width: 78, alignment: .top)
    }

    @ViewBuilder
    private var avatar: some View {
        if let value = member.profileURL, let url = URL(string: value) {
            CachedMovieImage(url: url, symbol: "person.fill")
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.secondary.opacity(0.32), Color.secondary.opacity(0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "person.fill")
                .foregroundStyle(.secondary)
        }
    }
}

private struct TipSheet: View {
    @ObservedObject var manager: TipPurchaseManager
    @Environment(\.dismiss) private var dismiss
    @State private var quantity = 1
    @State private var custom = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Support ReelSpan with a voluntary tip. Tips do not unlock any features.")
                    if manager.state == .loading { ProgressView() }
                    if manager.product != nil {
                        HStack {
                            ForEach([1, 3, 5], id: \.self) { value in
                                Button(manager.amount(quantity: value)) { quantity = value; custom = false }
                                    .buttonStyle(.bordered)
                                    .tint(!custom && quantity == value ? .accentColor : .secondary)
                            }
                        }
                        Toggle("Custom amount", isOn: $custom)
                        if custom {
                            Stepper("\(quantity) × \(manager.amount(quantity: 1))", value: $quantity, in: 1...10)
                        }
                        Button("Send \(manager.amount(quantity: quantity)) tip") {
                            Task { await manager.purchase(quantity: quantity) }
                        }
                        .disabled(manager.state.isBusy || manager.state == .pending)
                    }
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                    if manager.product == nil && !manager.state.isBusy {
                        Button("Try again") { Task { await manager.load() } }
                    }
                }
            }
            .navigationTitle("Tip ReelSpan")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .task { await manager.load() }
        .interactiveDismissDisabled(manager.state == .purchasing)
    }

    private var statusText: String {
        switch manager.state {
        case .unavailable: "Tips are currently unavailable in the App Store."
        case .loading: "Loading App Store prices…"
        case .ready: "Payment is handled by Apple."
        case .purchasing: "Waiting for Apple…"
        case .verified: "Thank you for supporting ReelSpan!"
        case .pending: "Your tip is awaiting approval."
        case .cancelled: "Payment was cancelled."
        case .unverified: "The App Store payment could not be verified."
        case .failed(let message): message
        }
    }
}
