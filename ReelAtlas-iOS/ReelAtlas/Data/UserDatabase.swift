import Foundation
import Combine
import SQLite3

final class UserDatabase {
    private let db: SQLiteDatabase

    init() throws {
        let fileManager=FileManager.default
        let support=try fileManager.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            .appendingPathComponent("ReelAtlas",isDirectory:true)
        try fileManager.createDirectory(at:support,withIntermediateDirectories:true)
        db=try SQLiteDatabase(url:support.appendingPathComponent("user.sqlite"),readOnly:false)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS favorites(movie_id INTEGER PRIMARY KEY, created_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS recent_searches(id INTEGER PRIMARY KEY AUTOINCREMENT, query TEXT NOT NULL, created_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS local_preferences(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
    }

    func favoriteIDs() -> Set<Int> {
        guard let statement=try? db.prepare("SELECT movie_id FROM favorites") else { return [] }
        defer { sqlite3_finalize(statement) }
        var result=Set<Int>()
        while (try? db.step(statement)) == true { result.insert(db.int(statement,0)) }
        return result
    }

    func setFavorite(movieID:Int,isFavorite:Bool) {
        if isFavorite {
            if let statement=try? db.prepare("INSERT OR REPLACE INTO favorites(movie_id,created_at) VALUES (?,?)",bindings:[.int(movieID),.double(Date().timeIntervalSince1970)]) {
                defer { sqlite3_finalize(statement) }; _=try? db.step(statement)
            }
        } else if let statement=try? db.prepare("DELETE FROM favorites WHERE movie_id=?",bindings:[.int(movieID)]) {
            defer { sqlite3_finalize(statement) }; _=try? db.step(statement)
        }
    }

    func replaceFavorites(with movieIDs: Set<Int>) {
        try? db.execute("BEGIN; DELETE FROM favorites;")
        for movieID in movieIDs {
            if let statement = try? db.prepare(
                "INSERT INTO favorites(movie_id,created_at) VALUES (?,?)",
                bindings: [.int(movieID), .double(Date().timeIntervalSince1970)]
            ) {
                _ = try? db.step(statement)
                sqlite3_finalize(statement)
            }
        }
        try? db.execute("COMMIT;")
    }
}

@MainActor
final class ICloudBackupManager: ObservableObject {
    enum Status: Equatable {
        case idle, syncing, success(Date), unavailable, failed(String)

        var text: String {
            switch self {
            case .idle: return "Not synced"
            case .syncing: return "Syncing…"
            case .success(let date): return "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
            case .unavailable: return "iCloud unavailable"
            case .failed: return "Sync failed"
            }
        }
    }

    @Published private(set) var status: Status = .idle
    nonisolated private static let containerIdentifier = "iCloud.com.xiaoguiwk.ReelSpan"

    func restore(localCacheDirectory: URL) async -> ICloudBackupManifest? {
        status = .syncing
        do {
            let result = try await Task.detached(priority: .utility) {
                try Self.restoreFiles(
                    containerIdentifier: Self.containerIdentifier,
                    localCacheDirectory: localCacheDirectory
                )
            }.value
            status = result.map { .success($0.updatedAt) } ?? .idle
            return result
        } catch ICloudBackupError.unavailable {
            status = .unavailable
        } catch {
            status = .failed(error.localizedDescription)
        }
        return nil
    }

    func backup(_ manifest: ICloudBackupManifest, localCacheDirectory: URL) async {
        status = .syncing
        do {
            try await Task.detached(priority: .utility) {
                try Self.backupFiles(
                    manifest: manifest,
                    containerIdentifier: Self.containerIdentifier,
                    localCacheDirectory: localCacheDirectory
                )
            }.value
            status = .success(manifest.updatedAt)
        } catch ICloudBackupError.unavailable {
            status = .unavailable
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    nonisolated private static func cloudDirectory(containerIdentifier: String) throws -> URL {
        guard let root = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            throw ICloudBackupError.unavailable
        }
        return root.appendingPathComponent("Documents/ReelSpanBackup", isDirectory: true)
    }

    nonisolated private static func restoreFiles(
        containerIdentifier: String,
        localCacheDirectory: URL
    ) throws -> ICloudBackupManifest? {
        let cloud = try cloudDirectory(containerIdentifier: containerIdentifier)
        let manifestURL = cloud.appendingPathComponent("user-backup.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        try? FileManager.default.startDownloadingUbiquitousItem(at: manifestURL)
        let manifest = try JSONDecoder().decode(ICloudBackupManifest.self, from: Data(contentsOf: manifestURL))
        try copyNewerFiles(
            from: cloud.appendingPathComponent("TMDB", isDirectory: true),
            to: localCacheDirectory
        )
        return manifest
    }

    nonisolated private static func backupFiles(
        manifest: ICloudBackupManifest,
        containerIdentifier: String,
        localCacheDirectory: URL
    ) throws {
        let cloud = try cloudDirectory(containerIdentifier: containerIdentifier)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: cloud.appendingPathComponent("user-backup.json"), options: .atomic)
        try copyNewerFiles(
            from: localCacheDirectory,
            to: cloud.appendingPathComponent("TMDB", isDirectory: true)
        )
    }

    nonisolated private static func copyNewerFiles(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys) else { return }
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let relative = String(file.path.dropFirst(source.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let target = destination.appendingPathComponent(relative)
            let targetValues = try? target.resourceValues(forKeys: Set(keys))
            if targetValues?.fileSize == values.fileSize,
               (targetValues?.contentModificationDate ?? .distantPast) >= (values.contentModificationDate ?? .distantPast) {
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: file, to: target)
        }
    }
}

private enum ICloudBackupError: Error { case unavailable }
