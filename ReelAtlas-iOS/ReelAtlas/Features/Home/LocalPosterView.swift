import SwiftUI

struct LocalPosterView: View {
    @EnvironmentObject private var model: AppModel
    let movie: MovieViewData
    let cornerRadius: CGFloat
    var isDetail = false

    private var url: URL? {
        if let id = movie.tmdbID, let metadata = model.metadataStore.metadataState(for: id).metadata {
            return isDetail ? metadata.posterURL : metadata.thumbnailPosterURL
        }
        return movie.largePosterURL.flatMap(URL.init(string:))
    }

    var body: some View {
        CachedMovieImage(url: url, symbol: "film")
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

/// The task belongs to this visible image; leaving or replacing its URL cancels the request.
struct CachedMovieImage: View {
    @EnvironmentObject private var model: AppModel
    let url: URL?
    var symbol = "photo"
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            do {
                let data = try await model.metadataStore.service.imageData(url: url)
                try Task.checkCancellation()
                image = UIImage(data: data)
            } catch { }
        }
    }
}
