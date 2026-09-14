import SwiftUI

struct MovieRowView: View {
    private let movie: MovieViewData
    let isFavorite: Bool
    let onFavorite: () -> Void

    init(movie: MovieViewData, isFavorite: Bool, onFavorite: @escaping () -> Void) {
        self.movie = movie
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

                Text("\(movie.releaseYearText) · \(L10n.runtime(movie.runtimeMinutes))")
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
