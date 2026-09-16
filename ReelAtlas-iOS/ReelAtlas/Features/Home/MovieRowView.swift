import SwiftUI

struct MovieRowView: View {
    @EnvironmentObject private var model: AppModel
    private let originalMovie: MovieViewData
    private var movie: MovieViewData {
        guard let id = originalMovie.tmdbID,
              let metadata = model.metadataStore.metadataState(for: id).metadata else { return originalMovie }
        return originalMovie.enriching(with: metadata)
    }
    let isFavorite: Bool
    let onFavorite: () -> Void

    init(movie: MovieViewData, isFavorite: Bool, onFavorite: @escaping () -> Void) {
        self.originalMovie = movie
        self.isFavorite = isFavorite
        self.onFavorite = onFavorite
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LocalPosterView(movie: movie, cornerRadius: 10)
                .frame(width: 72, height: 106)
                .clipped()

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(movie.title).font(.headline).lineLimit(2)
                    Spacer(minLength: 4)
                    Button(action: onFavorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(isFavorite ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(isFavorite ? "movie.favorite.added" : "movie.favorite.add"))
                }

                HStack(spacing: 8) {
                    Text("\(movie.releaseYearText) · \(L10n.runtime(movie.runtimeMinutes))")
                    if movie.rating > 0 {
                        Label(String(format: "TMDB %.1f", movie.rating), systemImage: "star.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if movie.genres.isEmpty {
                    FlowTags(tags: [L10n.text("movie.genre.unknown")])
                } else {
                    FlowTags(tags: Array(movie.genres.prefix(3)).map(GenreLocalization.displayName))
                }

                Label(L10n.storyLocation(movie.storyLocationText), systemImage: "mappin.and.ellipse")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Label(
                    movie.storyTimeText.isEmpty ? L10n.text("movie.time.unknown") : movie.storyTimeText,
                    systemImage: "clock"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onAppear { if let id = originalMovie.tmdbID { model.metadataStore.beginVisible(id) } }
        .onDisappear { if let id = originalMovie.tmdbID { model.metadataStore.endVisible(id) } }
    }
}

struct FlowTags: View {
    let tags: [String]
    var body: some View {
        HStack(spacing: 5) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
            }
        }
    }
}
