import AppKit
import CryptoKit
import Foundation
import SQLite3

enum LaunchpadStore {
    static func locate() throws -> URL {
        try PlatformSupport.requireSupportedOS()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
        process.arguments = ["DARWIN_USER_DIR"]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let base =
            String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines) ?? ""
        let url = URL(fileURLWithPath: base).appendingPathComponent("com.apple.dock.launchpad/db/db")
        guard !base.isEmpty, FileManager.default.fileExists(atPath: "/System/Applications/Launchpad.app"),
            FileManager.default.fileExists(atPath: url.path)
        else {
            throw StudioError(
                L(
                    "The original Launchpad could not be found. Launchpad Studio requires macOS 13–15 and the original Launchpad."
                ))
        }
        return url
    }
    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    static func read(_ db: Database) throws -> Snapshot {
        let info = try db.rows("SELECT key,value FROM dbinfo ORDER BY key")
        func value(_ key: String) -> String? { info.first(where: { $0["key"] == key })?["value"] }
        guard value("version") == "13", value("compatibleVersion") == "6", value("ignore_items_update_triggers") == "0"
        else {
            throw StudioError(
                L("The Launchpad format is unsupported or Dock is updating the layout. Refresh in a moment."))
        }
        guard try db.rows("SELECT item_id FROM downloading_apps").isEmpty else {
            throw StudioError(L("Wait for app downloads to finish, then refresh."))
        }
        let rows = try db.rows("SELECT rowid,uuid,flags,type,parent_id,ordering FROM items ORDER BY rowid")
        let groups = try db.rows("SELECT item_id,category_id,title FROM groups ORDER BY item_id")
        let appRows = try db.rows(
            "SELECT a.item_id,a.title,a.bundleid,c.uti,i.uuid FROM apps a JOIN items i ON i.rowid=a.item_id LEFT JOIN categories c ON c.rowid=a.category_id ORDER BY a.item_id"
        )
        guard rows.allSatisfy({ Int64($0["rowid"] ?? "") != nil && Int($0["ordering"] ?? "0") != nil }),
            appRows.allSatisfy({ Int64($0["item_id"] ?? "") != nil }),
            Set(appRows.compactMap { $0["item_id"] }).count == appRows.count
        else {
            throw StudioError(
                L("The Launchpad format is unsupported or Dock is updating the layout. Refresh in a moment."))
        }
        guard let root = Int64(value("launchpad_root") ?? ""),
            let holdingRow = rows.first(where: { $0["uuid"] == "HOLDINGPAGE" }),
            let holding = Int64(holdingRow["rowid"] ?? "")
        else { throw StudioError(L("Could not find the Launchpad root.")) }
        func children(_ parent: Int64) -> [[String: String]] {
            rows.filter { $0["parent_id"] == String(parent) }.sorted {
                Int($0["ordering"] ?? "0")! < Int($1["ordering"] ?? "0")!
            }
        }
        let allApps = appRows.map {
            AppRecord(
                id: Int64($0["item_id"]!)!, name: $0["title"] ?? L("Untitled"), bundleID: $0["bundleid"] ?? "",
                category: $0["uti"] ?? "", uuid: $0["uuid"] ?? "")
        }
        let lookup = Dictionary(uniqueKeysWithValues: allApps.map { ($0.id, $0) })
        var containers: [Int64] = []
        var pages: [LayoutPage] = []
        for page in children(root) where page["uuid"] != "HOLDINGPAGE" {
            guard page["type"] == "3", let pid = Int64(page["rowid"]!) else {
                throw StudioError(L("This page format is not supported."))
            }
            containers.append(pid)
            var tiles: [Tile] = []
            for row in children(pid) {
                let id = Int64(row["rowid"]!)!
                if row["type"] == "4", let app = lookup[id] {
                    tiles.append(Tile(id: "app-\(id)", name: app.name, appIDs: [id], isFolder: false))
                } else if row["type"] == "2" {
                    containers.append(id)
                    var ids: [Int64] = []
                    var sizes: [Int] = []
                    for fp in children(id) {
                        guard fp["type"] == "3" else { throw StudioError(L("Nested folders are not supported.")) }
                        let fpid = Int64(fp["rowid"]!)!
                        containers.append(fpid)
                        let children = children(fpid)
                        guard children.allSatisfy({ $0["type"] == "4" && lookup[Int64($0["rowid"]!)!] != nil }) else {
                            throw StudioError(L("This folder contains an unsupported item."))
                        }
                        ids.append(contentsOf: children.map { Int64($0["rowid"]!)! })
                        // Dock can leave an empty folder page during removal. It carries
                        // no app positions and must not make the saved draft invalid.
                        if !children.isEmpty { sizes.append(children.count) }
                    }
                    let name = groups.first(where: { $0["item_id"] == String(id) })?["title"] ?? L("Folder")
                    tiles.append(
                        Tile(
                            id: "folder-\(id)", name: name, appIDs: ids, pageSizes: sizes,
                            symbol: Classifier.style(name).0, color: Classifier.style(name).1))
                } else {
                    throw StudioError(L("Launchpad contains an unsupported item. The original data was not changed."))
                }
            }
            pages.append(LayoutPage(id: "page-\(pid)", tiles: tiles))
        }
        let layout = Layout(pages: pages)
        let visible = Set(layout.appIDs)
        let fingerprint = try digest([rows, groups, appRows, info])
        let catalog = try digest(appRows.map { [$0["item_id"] ?? "", $0["bundleid"] ?? "", $0["uuid"] ?? ""] })
        return Snapshot(
            layout: layout, apps: allApps.filter { visible.contains($0.id) }, fingerprint: fingerprint,
            catalog: catalog, containers: containers, root: root, holding: holding,
            hiddenCount: allApps.count - visible.count, allRows: rows)
    }
    static func snapshot(_ path: String) throws -> Snapshot {
        let db = try Database(path)
        try db.execute("BEGIN")
        defer { try? db.execute("ROLLBACK") }
        return try read(db)
    }
    // Caller owns the transaction. Only the visible tree is rebuilt; app rows and hidden roots remain intact.
    static func write(_ layout: Layout, to db: Database, baseline: Snapshot) throws {
        try layout.validated(for: baseline.apps)
        guard try read(db).fingerprint == baseline.fingerprint else {
            throw StudioError(L("Launchpad was changed elsewhere. Refresh before applying."))
        }
        try db.execute("UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers'")
        for id in baseline.layout.appIDs {
            try db.execute(
                "UPDATE items SET parent_id=?, ordering=0 WHERE rowid=?", [String(baseline.holding), String(id)])
        }
        for id in baseline.containers.reversed() {
            try db.execute("DELETE FROM items WHERE rowid=?", [String(id)])
            // Apple's delete trigger resets the trigger guard itself.
            try db.execute("UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers'")
        }
        func container(type: Int, parent: Int64, order: Int, name: String? = nil) throws -> Int64 {
            try db.execute(
                "INSERT INTO items(uuid,flags,type,parent_id,ordering) VALUES(?,?,?,?,?)",
                [UUID().uuidString, type == 3 ? "2" : "0", String(type), String(parent), String(order)])
            let id = sqlite3_last_insert_rowid(db.handle)
            try db.execute("INSERT INTO groups(item_id,category_id,title) VALUES(?,NULL,?)", [String(id), name])
            return id
        }
        for (pi, page) in layout.pages.enumerated() {
            let pageID = try container(type: 3, parent: baseline.root, order: pi + 1)
            for (ti, tile) in page.tiles.enumerated() {
                if tile.isFolder {
                    let folderID = try container(type: 2, parent: pageID, order: ti, name: tile.name)
                    let sizes = tile.effectivePageSizes
                    var offset = 0
                    for (fi, size) in sizes.enumerated() {
                        let fp = try container(type: 3, parent: folderID, order: fi)
                        for ai in 0..<size {
                            try db.execute(
                                "UPDATE items SET parent_id=?,ordering=? WHERE rowid=?",
                                [String(fp), String(ai), String(tile.appIDs[offset + ai])])
                        }
                        offset += size
                    }
                } else {
                    try db.execute(
                        "UPDATE items SET parent_id=?,ordering=? WHERE rowid=?",
                        [String(pageID), String(ti), String(tile.appIDs[0])])
                }
            }
        }
        try db.execute("UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers'")
        let result = try read(db)
        guard result.layout.semantic == layout.semantic, result.catalog == baseline.catalog else {
            throw StudioError(L("The result could not be verified. Changes will be rolled back."))
        }
        guard try db.rows("PRAGMA integrity_check").first?.values.first == "ok" else {
            throw StudioError(L("Data integrity check failed."))
        }
    }
}
