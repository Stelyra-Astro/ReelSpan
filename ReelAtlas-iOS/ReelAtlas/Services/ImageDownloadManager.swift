import Foundation
import Combine
import Security
@preconcurrency import Network

@MainActor
final class ImageDownloadManager: ObservableObject {
    enum Kind { case poster }
    enum LoadPriority { case visibleRow, detail }

    private struct LoadJob {
        let token: UUID
        let priority: LoadPriority
        let task: Task<Void, Never>
    }

    @Published var isDownloading = false
    @Published var progressText = ""
    @Published var cacheBytes: Int64 = 0
    @Published private(set) var hasTMDBAPIKey = false
    @Published private(set) var detailsByMovieID: [Int: TMDBMovieDetails] = [:]
    @Published private(set) var listRequestRevision = 0
    private var loadingMovieIDs = Set<Int>()
    private var activeVisibleMovieIDs = Set<Int>()
    private var loadJobs: [Int: LoadJob] = [:]
    private var detailMovieID: Int?
    var onCacheChanged: (() -> Void)?

    init() {
        hasTMDBAPIKey = KeychainAPIKeyStore.load() != nil
        removeLegacyOversizedArtwork()
        removeExpiredFiles()
        trimCacheIfNeeded()
        refreshCacheSize()
    }

    func cachedURL(movieID: Int, kind: Kind) -> URL? {
        let url = directory(for: kind).appendingPathComponent("\(movieID).jpg")
        guard !isExpired(url) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func enrichedMovie(_ movie: MovieViewData) -> MovieViewData {
        detailsByMovieID[movie.id].map(movie.enriching) ?? movie
    }

    func saveTMDBAPIKey(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard KeychainAPIKeyStore.save(key) else {
            progressText = L10n.text("images.tmdb.key_save_failed")
            return
        }
        hasTMDBAPIKey = true
        progressText = ""
    }

    func loadDetails(
        for movie: MovieViewData,
        language: String,
        priority: LoadPriority = .visibleRow
    ) async {
        if priority == .detail {
            detailMovieID = movie.id
            cancelJobs(except: movie.id)
            if let existing = loadJobs[movie.id], existing.priority == .visibleRow {
                existing.task.cancel()
                loadJobs.removeValue(forKey: movie.id)
            }
        } else if detailMovieID != nil {
            return
        }

        if let existing = loadJobs[movie.id] {
            await existing.task.value
            return
        }

        let token = UUID()
        let task = Task(priority: priority == .detail ? .userInitiated : .utility) { [weak self] in
            guard let self else { return }
            await self.runScheduledLoad(for: movie, language: language, priority: priority)
        }
        loadJobs[movie.id] = LoadJob(token: token, priority: priority, task: task)
        await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelJob(movieID: movie.id, token: token) }
        })
        finishJob(movieID: movie.id, token: token)
    }

    func endDetail(movieID: Int) {
        guard detailMovieID == movieID else { return }
        detailMovieID = nil
        loadJobs[movieID]?.task.cancel()
        loadJobs.removeValue(forKey: movieID)
        listRequestRevision += 1
    }

    private func runScheduledLoad(
        for movie: MovieViewData,
        language: String,
        priority: LoadPriority
    ) async {
        if priority == .visibleRow {
            while activeVisibleMovieIDs.count >= ArtworkCachePolicy.maximumConcurrentVisibleRequests {
                do {
                    try Task.checkCancellation()
                    guard detailMovieID == nil else { return }
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch { return }
            }
            guard detailMovieID == nil else { return }
            activeVisibleMovieIDs.insert(movie.id)
            await performLoad(for: movie, language: language)
            activeVisibleMovieIDs.remove(movie.id)
            return
        }
        await performLoad(for: movie, language: language)
    }

    private func performLoad(for movie: MovieViewData, language: String) async {
        guard let tmdbID = movie.tmdbID,
              detailsByMovieID[movie.id] == nil,
              !loadingMovieIDs.contains(movie.id) else { return }
        if let cached = cachedDetails(movieID: movie.id, language: language) {
            detailsByMovieID[movie.id] = cached
            await cacheArtwork(cached, movieID: movie.id)
            return
        }
        guard let key = KeychainAPIKeyStore.load() else { return }

        loadingMovieIDs.insert(movie.id)
        isDownloading = true
        defer {
            loadingMovieIDs.remove(movie.id)
            isDownloading = !loadingMovieIDs.isEmpty
            refreshCacheSize()
        }
        do {
            let details = try await fetchDetails(movieID: tmdbID, apiKey: key, language: language)
            try Task.checkCancellation()
            detailsByMovieID[movie.id] = details
            saveDetails(details, movieID: movie.id, language: language)
            await cacheArtwork(details, movieID: movie.id)
        } catch TMDBServiceError.invalidAPIKey {
            progressText = L10n.text("images.tmdb.invalid_key")
        } catch is CancellationError {
            return
        } catch {
            // Loading visible artwork is best-effort; transient network failures stay silent.
            return
        }
    }

    private func cancelJobs(except movieID: Int) {
        let jobsToCancel = loadJobs.filter { $0.key != movieID }
        for (id, job) in jobsToCancel {
            job.task.cancel()
            loadJobs.removeValue(forKey: id)
        }
    }

    private func cancelJob(movieID: Int, token: UUID) {
        guard let job = loadJobs[movieID], job.token == token else { return }
        job.task.cancel()
        loadJobs.removeValue(forKey: movieID)
    }

    private func finishJob(movieID: Int, token: UUID) {
        guard loadJobs[movieID]?.token == token else { return }
        loadJobs.removeValue(forKey: movieID)
    }

    func clearTMDBAPIKey() {
        KeychainAPIKeyStore.delete()
        hasTMDBAPIKey = false
        progressText = L10n.text("images.tmdb.key_removed")
    }

    func clear() {
        try? FileManager.default.removeItem(at: baseDirectory)
        detailsByMovieID = [:]
        refreshCacheSize()
        progressText = L10n.text("images.cleared")
    }

    func refreshCacheSize() {
        guard let enumerator = FileManager.default.enumerator(
            at: baseDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { cacheBytes = 0; return }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { total += Int64(size) }
        }
        cacheBytes = total
    }

    var cacheSizeText: String { ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file) }
    var cacheDirectoryForBackup: URL { baseDirectory }

    private var baseDirectory: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("ReelAtlas/TMDB", isDirectory: true)
    }

    private func directory(for kind: Kind) -> URL {
        baseDirectory.appendingPathComponent("Posters-w185", isDirectory: true)
    }

    private var metadataDirectory: URL { baseDirectory.appendingPathComponent("Metadata", isDirectory: true) }

    private func metadataURL(movieID: Int, language: String) -> URL {
        metadataDirectory.appendingPathComponent("\(movieID)-\(language.replacingOccurrences(of: "/", with: "-")).json")
    }

    private func cachedDetails(movieID: Int, language: String) -> TMDBMovieDetails? {
        let url = metadataURL(movieID: movieID, language: language)
        guard !isExpired(url), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TMDBMovieDetails.self, from: data)
    }

    private func saveDetails(_ details: TMDBMovieDetails, movieID: Int, language: String) {
        try? FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(details) else { return }
        try? data.write(to: metadataURL(movieID: movieID, language: language), options: .atomic)
    }

    private func fetchDetails(movieID: Int, apiKey: String, language: String) async throws -> TMDBMovieDetails {
        var components = URLComponents(string: "https://api.themoviedb.org/3/movie/\(movieID)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "append_to_response", value: "credits"),
            URLQueryItem(name: "language", value: language)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result: (Data, Int)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TMDBServiceError.badResponse }
            result = (data, http.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            result = try await TMDBDirectIPTransport.fetchAPI(
                path: components.url!.path + "?" + (components.percentEncodedQuery ?? "")
            )
        }
        if result.1 == 401 || result.1 == 403 { throw TMDBServiceError.invalidAPIKey }
        guard (200...299).contains(result.1) else { throw TMDBServiceError.badResponse }
        return try JSONDecoder().decode(TMDBMovieDetails.self, from: result.0)
    }

    private func cacheArtwork(_ details: TMDBMovieDetails, movieID: Int) async {
        await downloadIfNeeded(details.posterURL, movieID: movieID, kind: .poster)
        trimCacheIfNeeded()
        objectWillChange.send()
        onCacheChanged?()
    }

    private func downloadIfNeeded(_ url: URL?, movieID: Int, kind: Kind) async {
        guard cachedURL(movieID: movieID, kind: kind) == nil, let url else { return }
        do {
            let data: Data
            do {
                let result = try await URLSession.shared.data(from: url)
                guard let http = result.1 as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else { return }
                data = result.0
            } catch {
                let result = try await TMDBDirectIPTransport.fetchImage(path: url.path)
                guard (200...299).contains(result.1) else { return }
                data = result.0
            }
            guard !data.isEmpty else { return }
            let folder = directory(for: kind)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("\(movieID).jpg"), options: .atomic)
        } catch { }
    }

    private func isExpired(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return false
        }
        return Date().timeIntervalSince(date) > ArtworkCachePolicy.maximumAge
    }

    private func removeLegacyOversizedArtwork() {
        try? FileManager.default.removeItem(at: baseDirectory.appendingPathComponent("LargePosters"))
        try? FileManager.default.removeItem(at: baseDirectory.appendingPathComponent("Backdrops"))
    }

    private func removeExpiredFiles() {
        guard let enumerator = FileManager.default.enumerator(
            at: baseDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for case let url as URL in enumerator where isExpired(url) { try? FileManager.default.removeItem(at: url) }
    }

    private func trimCacheIfNeeded() {
        guard let enumerator = FileManager.default.enumerator(
            at: baseDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        ) else { return }
        var files: [(URL, Int64, Date)] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]),
                  let size = values.fileSize else { continue }
            let bytes = Int64(size)
            total += bytes
            files.append((url, bytes, values.contentAccessDate ?? values.contentModificationDate ?? .distantPast))
        }
        for file in files.sorted(by: { $0.2 < $1.2 }) where total > ArtworkCachePolicy.maximumBytes {
            if (try? FileManager.default.removeItem(at: file.0)) != nil { total -= file.1 }
        }
    }
}

private enum TMDBServiceError: Error { case invalidAPIKey, badResponse }

private enum TMDBDirectIPTransport {
    private static let apiHost = "api.themoviedb.org"
    private static let apiAddresses = [
        "13.224.161.90", "13.35.67.86", "13.226.238.76", "13.35.7.102",
        "13.225.103.26", "13.226.191.85", "13.225.103.110", "52.85.79.89",
        "13.225.41.40", "13.226.251.88"
    ]

    static func fetchAPI(path: String) async throws -> (Data, Int) {
        try await fetch(host: apiHost, addresses: apiAddresses, path: path)
    }

    static func fetchImage(path: String) async throws -> (Data, Int) {
        try await fetch(host: "image.tmdb.org", addresses: ["104.16.61.155"], path: path)
    }

    private static func fetch(host: String, addresses: [String], path: String) async throws -> (Data, Int) {
        var lastError: Error = TMDBServiceError.badResponse
        for address in addresses {
            try Task.checkCancellation()
            do { return try await fetch(host: host, address: address, path: path) }
            catch { lastError = error }
        }
        throw lastError
    }

    private static func fetch(host: String, address: String, path: String) async throws -> (Data, Int) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 4
        let connection = NWConnection(host: NWEndpoint.Host(address), port: .https, using: NWParameters(tls: tls, tcp: tcp))
        let box = DirectResponseBox(connection: connection)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                box.continuation = continuation
                connection.stateUpdateHandler = { state in
                    switch state {
                case .ready:
                    let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nAccept: application/json\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"
                    connection.send(content: request.data(using: .utf8), completion: .contentProcessed { error in
                        if let error { box.finish(.failure(error)) } else { box.receive() }
                    })
                case .failed(let error): box.finish(.failure(error))
                case .cancelled: box.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        }, onCancel: {
            box.finish(.failure(CancellationError()))
        })
    }
}

private final class DirectResponseBox: @unchecked Sendable {
    let connection: NWConnection
    var continuation: CheckedContinuation<(Data, Int), Error>?
    private var bytes = Data()
    private let lock = NSLock()
    private var finished = false

    init(connection: NWConnection) { self.connection = connection }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { data, _, complete, error in
            if let data { self.lock.withLock { self.bytes.append(data) } }
            if let error { self.finish(.failure(error)); return }
            if complete {
                do { self.finish(.success(try Self.parse(self.lock.withLock { self.bytes }))) }
                catch { self.finish(.failure(error)) }
            } else { self.receive() }
        }
    }

    func finish(_ result: Result<(Data, Int), Error>) {
        let value: CheckedContinuation<(Data, Int), Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            defer { continuation = nil }
            return continuation
        }
        connection.cancel()
        value?.resume(with: result)
    }

    private static func parse(_ data: Data) throws -> (Data, Int) {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<range.lowerBound], encoding: .utf8),
              let statusText = header.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first,
              let status = Int(statusText) else { throw TMDBServiceError.badResponse }
        let body = Data(data[range.upperBound...])
        return (header.lowercased().contains("transfer-encoding: chunked") ? try decodeChunked(body) : body, status)
    }

    private static func decodeChunked(_ data: Data) throws -> Data {
        var input = data
        var output = Data()
        while true {
            guard let lineRange = input.range(of: Data("\r\n".utf8)),
                  let line = String(data: input[..<lineRange.lowerBound], encoding: .ascii),
                  let size = Int(line.split(separator: ";", maxSplits: 1)[0], radix: 16) else {
                throw TMDBServiceError.badResponse
            }
            input.removeSubrange(..<lineRange.upperBound)
            if size == 0 { return output }
            guard input.count >= size + 2 else { throw TMDBServiceError.badResponse }
            output.append(input.prefix(size))
            input.removeSubrange(..<input.index(input.startIndex, offsetBy: size + 2))
        }
    }
}

private enum KeychainAPIKeyStore {
    private static let service = "com.xiaoguiwk.ReelSpan.tmdb"
    private static let account = "api-key"

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var item = baseQuery
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() { SecItemDelete(baseQuery as CFDictionary) }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    }
}
