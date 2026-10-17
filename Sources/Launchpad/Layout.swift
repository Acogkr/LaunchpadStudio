import Foundation

struct AppRecord: Identifiable, Codable, Equatable {
    var id: Int64
    var name: String
    var bundleID: String
    var category: String
    var uuid: String
    var path: String?
}
struct Tile: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var appIDs: [Int64]
    var isFolder = true
    var pageSizes: [Int] = []
    var symbol: String = "folder.fill"
    var color: String = "blue"
    var effectivePageSizes: [Int] {
        pageSizes.isEmpty ? stride(from: 0, to: appIDs.count, by: 35).map { min(35, appIDs.count - $0) } : pageSizes
    }
    mutating func repaginate() {
        pageSizes = stride(from: 0, to: appIDs.count, by: 35).map { min(35, appIDs.count - $0) }
    }
    var appPages: [[Int64]] {
        var offset = 0
        var result: [[Int64]] = []
        for size in effectivePageSizes {
            guard size > 0, size <= 35, size <= appIDs.count - offset else {
                return stride(from: 0, to: appIDs.count, by: 35).map { Array(appIDs[$0..<min($0 + 35, appIDs.count)]) }
            }
            result.append(Array(appIDs[offset..<offset + size]))
            offset += size
        }
        if offset != appIDs.count {
            return stride(from: 0, to: appIDs.count, by: 35).map { Array(appIDs[$0..<min($0 + 35, appIDs.count)]) }
        }
        return result
    }
    mutating func remapApps(_ transform: (Int64) -> Int64?) {
        let pages = appPages.map { $0.compactMap(transform) }.filter { !$0.isEmpty }
        appIDs = pages.flatMap { $0 }
        pageSizes = pages.map(\.count)
    }
    mutating func appendApps(_ ids: [Int64]) {
        var pages = appPages
        for id in ids {
            if pages.isEmpty || pages.last!.count == 35 { pages.append([]) }
            pages[pages.count - 1].append(id)
        }
        appIDs = pages.flatMap { $0 }
        pageSizes = pages.map(\.count)
    }
}
struct LayoutPage: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var tiles: [Tile]
}
struct Layout: Codable, Equatable {
    enum ValidationPurpose { case draft, apply }
    var pages: [LayoutPage]
    var tiles: [Tile] { pages.flatMap(\.tiles) }
    var appIDs: [Int64] { tiles.flatMap(\.appIDs) }
    var folderCount: Int { tiles.filter(\.isFolder).count }
    func location(_ id: Int64) -> String {
        for (pi, p) in pages.enumerated() {
            for (ti, t) in p.tiles.enumerated() where t.appIDs.contains(id) {
                return "\(pi + 1)|\(ti)|\(t.isFolder ? t.name : "")|\(t.appIDs.firstIndex(of: id) ?? 0)"
            }
        }
        return ""
    }
    func label(_ id: Int64) -> String {
        for (i, p) in pages.enumerated() {
            if let t = p.tiles.first(where: { $0.appIDs.contains(id) }) {
                return t.isFolder ? t.name : L("Page {0}", i + 1)
            }
        }
        return L("None")
    }
    var semantic: String {
        struct Content: Encodable {
            let folder: Bool
            let name: String
            let apps: [Int64]
            let sizes: [Int]
        }
        let contents = pages.map {
            $0.tiles.map {
                Content(
                    folder: $0.isFolder, name: $0.name, apps: $0.appIDs, sizes: $0.isFolder ? $0.effectivePageSizes : []
                )
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Only strings, integers, booleans, and arrays are encoded, so encoding cannot fail.
        return String(decoding: try! encoder.encode(contents), as: UTF8.self)
    }
    func validated(for apps: [AppRecord], capacity: Int = 35, purpose: ValidationPurpose = .apply) throws {
        guard !pages.isEmpty, pages.allSatisfy({ $0.tiles.count <= capacity }) else {
            throw StudioError(L("A page can contain at most {0} items.", capacity))
        }
        guard Set(pages.map(\.id)).count == pages.count, Set(tiles.map(\.id)).count == tiles.count,
            pages.allSatisfy({ !$0.id.isEmpty }), tiles.allSatisfy({ !$0.id.isEmpty })
        else {
            throw StudioError(L("The layout contains invalid or duplicate item IDs."))
        }
        guard Set(appIDs) == Set(apps.map(\.id)), appIDs.count == apps.count else {
            throw StudioError(L("Missing or duplicate apps were found. Nothing was applied."))
        }
        for t in tiles {
            guard !t.appIDs.isEmpty || (purpose == .draft && t.isFolder) else {
                throw StudioError(L("Add an app to the empty folder “{0}”, or delete the folder.", t.name))
            }
            if t.isFolder {
                guard !t.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, t.name.count <= 60,
                    !t.name.contains("\0")
                else { throw StudioError(L("Folder names must contain 1–60 characters.")) }
                if !t.pageSizes.isEmpty {
                    var remaining = t.appIDs.count
                    for size in t.pageSizes {
                        guard size > 0, size <= 35, size <= remaining else {
                            throw StudioError(L("The folder page structure is invalid."))
                        }
                        remaining -= size
                    }
                    guard remaining == 0 else { throw StudioError(L("The folder page structure is invalid.")) }
                }
            } else if t.appIDs.count != 1 {
                throw StudioError(L("An app item on this page is invalid."))
            }
        }
    }
}

struct Snapshot {
    let layout: Layout
    let apps: [AppRecord]
    let fingerprint: String
    let catalog: String
    let containers: [Int64]
    let root: Int64
    let holding: Int64
    let hiddenCount: Int
    let allRows: [[String: String]]
}
