import XCTest
@testable import ReelAtlasCore

private struct OfflineCacheTransport: MovieHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw MovieMetadataError.offline }
}

final class CachePreservationTests: XCTestCase {
    func testUpgradeDiscoversExpiredLegacyMetadataWithoutPageSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let historicalClock = Date(timeIntervalSince1970: 100)
        let writer = MovieMetadataCache(root: root, now: { historicalClock })
        try writer.writeMetadata(.fixture(id: 550), tmdbID: 550)
        try writer.writeMetadata(.fixture(id: 551), tmdbID: 551)

        let freshProcess = MovieMetadataCache(root: root)
        XCTAssertEqual(Set(freshProcess.cachedMetadataIDs()), Set([550, 551]))
        XCTAssertEqual(try freshProcess.readMetadata(tmdbID: 550, allowExpired: true)?.id, 550)
        XCTAssertEqual(try freshProcess.readMetadata(tmdbID: 551, allowExpired: true)?.id, 551)
    }
    func testUndecodableOlderMetadataIsRetainedForMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("movie-en-US-550.json")
        let bytes = Data("{\"older_format\":true}".utf8)
        try bytes.write(to: path)
        XCTAssertNil(try MovieMetadataCache(root: root).readMetadata(tmdbID: 550))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    func testMovieMetadataNeverExpiresOrGetsEvictedByImageBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MovieMetadataCache(root: root, maximumBytes: 1,
                                       now: { Date(timeIntervalSince1970: 100) })
        try cache.writeMetadata(.fixture(id: 550), tmdbID: 550)
        let image = URL(string: "https://example.org/cover.jpg")!
        try cache.writeImage(Data(repeating: 1, count: 300), for: image)
        XCTAssertEqual(try MovieMetadataCache(root: root).readMetadata(tmdbID: 550)?.id, 550)
    }

    func testExpiredMetadataSurvivesRefreshAndWorksOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldDate = Date(timeIntervalSince1970: 100)
        try MovieMetadataCache(root: root, now: { oldDate }).writeMetadata(.fixture(id: 550), tmdbID: 550)
        let cache = MovieMetadataCache(root: root)
        XCTAssertEqual(try cache.readMetadata(tmdbID: 550)?.id, 550)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("movie-en-US-550.json").path))
        let service = MovieMetadataService(transport: OfflineCacheTransport(), cache: cache)
        let metadata = try await service.metadata(tmdbID: 550)
        XCTAssertEqual(metadata.id, 550)
    }
}
