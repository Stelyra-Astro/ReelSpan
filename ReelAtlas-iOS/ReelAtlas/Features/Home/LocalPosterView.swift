import SwiftUI

struct LocalPosterView: View {
    let movie: MovieViewData
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let url = PosterAssetURL.url(assetID: movie.tmdbID) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.brown.opacity(0.8), Color.orange.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(movie.title)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(6)
        }
    }
}
