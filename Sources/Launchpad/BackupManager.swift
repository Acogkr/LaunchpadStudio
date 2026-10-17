import CryptoKit
import Foundation

struct BackupRecord: Identifiable, Codable {
    var id: String
    var date: Date
    var reason: String
    var appCount: Int
    var folderCount: Int
    var catalog: String
    var sha256: String
    var sourcePath: String
}
final class BackupManager {
    let root: URL
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func list() -> [BackupRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url -> BackupRecord? in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(BackupRecord.self, from: data)
        }.sorted { $0.date > $1.date }
    }
    func create(source: URL, reason: String) throws -> BackupRecord {
        let id = UUID().uuidString
        let destination = root.appendingPathComponent(id + ".sqlite")
        do {
            let db = try Database(source.path)
            try db.snapshot(to: destination)
            let snapshot = try LaunchpadStore.snapshot(destination.path)
            let sha = SHA256.hash(data: try Data(contentsOf: destination)).map { String(format: "%02x", $0) }.joined()
            let record = BackupRecord(
                id: id, date: Date(), reason: reason, appCount: snapshot.apps.count,
                folderCount: snapshot.layout.folderCount, catalog: snapshot.catalog, sha256: sha,
                sourcePath: source.resolvingSymlinksInPath().path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let metadata = root.appendingPathComponent(id + ".json")
            try encoder.encode(record).write(to: metadata, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
            return record
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
    func read(_ record: BackupRecord) throws -> Snapshot {
        guard UUID(uuidString: record.id) != nil else { throw StudioError(L("Invalid backup ID.")) }
        let file = root.appendingPathComponent(record.id + ".sqlite")
        let sha = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard sha == record.sha256 else {
            throw StudioError(L("The backup is damaged or modified. Restore was stopped."))
        }
        return try LaunchpadStore.snapshot(file.path)
    }
}
