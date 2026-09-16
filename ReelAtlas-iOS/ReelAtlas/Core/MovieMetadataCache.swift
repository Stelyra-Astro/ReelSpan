#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

public final class MovieMetadataCache {
    private let root: URL
    private let maximumBytes: Int64
    private let now: () -> Date
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        root: URL? = nil,
        maximumBytes: Int64 = MovieCachePolicy.maximumBytes,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.root = root ?? Self.defaultRoot(using: fileManager)
        self.maximumBytes = maximumBytes
        self.now = now
        self.fileManager = fileManager
    }

    public func readMetadata(tmdbID: Int, allowExpired: Bool = false) throws -> MovieMetadata? {
        try withLock {
            let url = metadataURL(tmdbID: tmdbID)
            guard let data = try readData(at: url, allowExpired: allowExpired) else { return nil }
            do {
                let metadata = try JSONDecoder().decode(MovieMetadata.self, from: data)
                try refreshAccessDate(for: url)
                return metadata
            } catch {
                // Preserve older-format bytes until a successful refresh/migration replaces them.
                return nil
            }
        }
    }

    public func writeMetadata(_ metadata: MovieMetadata, tmdbID: Int) throws {
        try withLock {
            try write(JSONEncoder().encode(metadata), to: metadataURL(tmdbID: tmdbID))
        }
    }

    public func cachedImage(for url: URL, allowExpired: Bool = false) -> Data? {
        withLock {
            do {
                guard let data = try readData(at: imageURL(for: url), allowExpired: allowExpired) else { return nil }
                try refreshAccessDate(for: imageURL(for: url))
                return data
            } catch {
                return nil
            }
        }
    }

    public func writeImage(_ data: Data, for url: URL) throws {
        try withLock {
            try write(data, to: imageURL(for: url))
        }
    }

    func rawData(key: String) -> Data? {
        withLock {
            do {
                let url = rawURL(key: key)
                guard let data = try readData(at: url) else { return nil }
                try refreshAccessDate(for: url)
                return data
            } catch {
                return nil
            }
        }
    }

    func writeRaw(_ data: Data, key: String) throws {
        try withLock {
            try write(data, to: rawURL(key: key))
        }
    }

    public func trim() throws {
        try withLock {
            try trimCacheEntries()
        }
    }

    public func clear() throws {
        try withLock {
            guard fileManager.fileExists(atPath: root.path) else { return }
            try fileManager.removeItem(at: root)
        }
    }

    public func totalBytes() -> Int64 {
        withLock {
            guard fileManager.fileExists(atPath: root.path),
                  let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                  ) else { return 0 }
            var total: Int64 = 0
            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true,
                      let size = values.fileSize else { continue }
                total += Int64(size)
            }
            return total
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        try refreshAccessDate(for: url)
        try trimCacheEntries()
    }

    private func readData(at url: URL, allowExpired: Bool = false) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        // Expiration requests a refresh; it does not delete the last offline copy.
        guard allowExpired || !isExpired(url) else { return nil }
        return try Data(contentsOf: url)
    }

    private func trimCacheEntries() throws {
        guard fileManager.fileExists(atPath: root.path) else { return }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentAccessDateKey,
            .contentModificationDateKey
        ]
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        var files: [(url: URL, bytes: Int64, accessDate: Date, modificationDate: Date)] = []
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, let size = values.fileSize else { continue }

            let bytes = Int64(size)
            let modificationDate = values.contentModificationDate ?? .distantPast
            let accessDate = values.contentAccessDate ?? modificationDate
            total += bytes
            files.append((url, bytes, accessDate, modificationDate))
        }

        for file in files.sorted(by: {
            if $0.accessDate != $1.accessDate { return $0.accessDate < $1.accessDate }
            return $0.modificationDate < $1.modificationDate
        }) where total > maximumBytes {
            try fileManager.removeItem(at: file.url)
            total -= file.bytes
        }
    }

    private func isExpired(_ url: URL, modificationDate: Date? = nil) -> Bool {
        guard let date = modificationDate ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey])).flatMap(\.contentModificationDate) else {
            return false
        }
        return now().timeIntervalSince(date) > MovieCachePolicy.maximumAge
    }

    private func refreshAccessDate(for url: URL) throws {
        var values = URLResourceValues()
        values.contentAccessDate = now()
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private func metadataURL(tmdbID: Int) -> URL {
        root.appendingPathComponent("movie-en-US-\(tmdbID).json")
    }

    private func imageURL(for url: URL) -> URL {
        root.appendingPathComponent("image-\(digest(url.absoluteURL.absoluteString)).bin")
    }

    private func rawURL(key: String) -> URL {
        root.appendingPathComponent("raw-\(digest(key)).bin")
    }

    private func digest(_ value: String) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        // Deterministic fallback for non-Apple SwiftPM test hosts. Cache filenames do not
        // require cryptographic strength; Apple platforms use SHA-256 above.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
        #endif
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func defaultRoot(using fileManager: FileManager) -> URL {
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return support.appendingPathComponent("ReelAtlas/MovieMetadata-v1", isDirectory: true)
    }
}
