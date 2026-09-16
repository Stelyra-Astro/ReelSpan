import XCTest
@testable import ReelAtlasCore

private struct OfflineCacheTransport: MovieHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw MovieMetadataError.offline }
}

final class CachePreservationTests: XCTestCase {
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
    func testExpiredMetadataSurvivesRefreshAndWorksOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldDate = Date(timeIntervalSince1970: 100)
        try MovieMetadataCache(root: root, now: { oldDate }).writeMetadata(.fixture(id: 550), tmdbID: 550)
        let cache = MovieMetadataCache(root: root)
        XCTAssertNil(try cache.readMetadata(tmdbID: 550))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("movie-en-US-550.json").path))
        let service = MovieMetadataService(transport: OfflineCacheTransport(), cache: cache)
        let metadata = try await service.metadata(tmdbID: 550)
        XCTAssertEqual(metadata.id, 550)
    }
}
