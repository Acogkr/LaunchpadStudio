import Foundation

struct DraftAppIdentity: Codable {
    let id: Int64
    let bundleID: String
    let uuid: String

    init(_ app: AppRecord) {
        id = app.id
        bundleID = app.bundleID
        uuid = app.uuid
    }
    var record: AppRecord { AppRecord(id: id, name: "", bundleID: bundleID, category: "", uuid: uuid) }
}

extension Draft {
    init(snapshot: Snapshot, layout: Layout) {
        self.init(
            fingerprint: snapshot.fingerprint, layout: layout, identities: snapshot.apps.map(DraftAppIdentity.init),
            baselineLayout: snapshot.layout)
    }

    func restored(for snapshot: Snapshot, apps: [AppRecord]) throws -> Layout {
        if fingerprint == snapshot.fingerprint {
            try layout.validated(for: apps, purpose: .draft)
            return layout
        }
        // Older drafts have no stable identities. Do not guess from reusable row IDs.
        guard let identities else {
            throw StudioError(
                L(
                    "This file was created from a different Launchpad layout. Import was stopped because app IDs may have changed."
                ))
        }
        guard Set(identities.map(\.id)).count == identities.count,
            Set(identities.map(\.uuid)).count == identities.count,
            identities.allSatisfy({ !$0.uuid.isEmpty })
        else {
            throw StudioError(L("The saved app list is invalid."))
        }
        try layout.validated(for: identities.map(\.record), purpose: .draft)
        let currentByUUID = Dictionary(grouping: apps, by: \.uuid)
        var remapping: [Int64: Int64] = [:]
        for identity in identities {
            if let matches = currentByUUID[identity.uuid], matches.count == 1, matches[0].bundleID == identity.bundleID
            {
                remapping[identity.id] = matches[0].id
            }
        }
        guard !remapping.isEmpty || identities.isEmpty else {
            throw StudioError(
                L(
                    "This file was created from a different Launchpad layout. Import was stopped because app IDs may have changed."
                ))
        }

        var restored = layout
        for p in restored.pages.indices {
            restored.pages[p].tiles = restored.pages[p].tiles.compactMap { original in
                var tile = original
                tile.appIDs = original.appIDs.compactMap { remapping[$0] }
                // Keep deliberately empty draft folders, but remove items uninstalled since saving.
                if !original.appIDs.isEmpty && tile.appIDs.isEmpty { return nil }
                if tile.isFolder {
                    if tile.appIDs != original.appIDs {
                        tile = original
                        tile.remapApps { remapping[$0] }
                    }
                } else if let id = tile.appIDs.first, let app = apps.first(where: { $0.id == id }) {
                    tile.id = "app-\(id)"
                    tile.name = app.name
                }
                return tile
            }
        }
        restored.pages.removeAll { $0.tiles.isEmpty }
        let retainedIDs = Set(restored.appIDs)
        let added = apps.filter { !retainedIDs.contains($0.id) }.sorted {
            $0.name == $1.name ? $0.id < $1.id : L10n.ordered($0.name, $1.name)
        }
        // New apps appear after the saved arrangement; custom folders and ordering stay intact.
        for app in added {
            if restored.pages.isEmpty || restored.pages.last!.tiles.count >= 35 {
                restored.pages.append(LayoutPage(tiles: []))
            }
            restored.pages[restored.pages.count - 1].tiles.append(
                Tile(id: "app-\(app.id)", name: app.name, appIDs: [app.id], isFolder: false))
        }
        try restored.validated(for: apps, purpose: .draft)
        return restored
    }
}

extension Layout {
    // Compare only surviving apps; installing/removing an app is not a competing edit.
    func arrangement(of ids: Set<Int64>) -> String {
        var value = self
        for p in value.pages.indices {
            value.pages[p].tiles = value.pages[p].tiles.compactMap { original in
                var tile = original
                tile.remapApps { ids.contains($0) ? $0 : nil }
                guard !tile.appIDs.isEmpty else { return nil }
                if !tile.isFolder { tile.name = "" }
                return tile
            }
        }
        value.pages.removeAll { $0.tiles.isEmpty }
        return value.semantic
    }
}
extension Draft {
    func synchronized(for snapshot: Snapshot, apps: [AppRecord]) throws -> Layout {
        if let baselineLayout, baselineLayout.semantic == layout.semantic, syncConflict != true {
            return snapshot.layout
        }
        return try restored(for: snapshot, apps: apps)
    }
    func needsSyncReview(for snapshot: Snapshot, apps: [AppRecord]) throws -> Bool {
        if syncConflict == true { return true }
        guard fingerprint != snapshot.fingerprint else { return false }
        guard var base = baselineLayout else { return true }
        // Older drafts may contain zero-sized pages read from a transitional Dock layout.
        for p in base.pages.indices {
            for t in base.pages[p].tiles.indices { base.pages[p].tiles[t].pageSizes.removeAll { $0 == 0 } }
        }
        guard base.semantic != layout.semantic else { return false }
        if try restored(for: snapshot, apps: apps).semantic == snapshot.layout.semantic { return false }
        var prior = self
        prior.layout = base
        let rebased = try prior.restored(for: snapshot, apps: apps)
        let known = Set((identities ?? []).map { $0.uuid + "|" + $0.bundleID })
        let surviving = Set(apps.filter { known.contains($0.uuid + "|" + $0.bundleID) }.map(\.id))
        return rebased.arrangement(of: surviving) != snapshot.layout.arrangement(of: surviving)
    }
}
