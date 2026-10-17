import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Preferences: Codable {
    var rules: [Rule] = []
    var locked: Set<Int64> = []
    var preserveFolders = false
    var lockedIdentities: [DraftAppIdentity]? = nil
    var deletionProtected: Set<String> = []

    init() {}
    enum CodingKeys: String, CodingKey { case rules, locked, preserveFolders, lockedIdentities, deletionProtected }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rules = try values.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        locked = try values.decodeIfPresent(Set<Int64>.self, forKey: .locked) ?? []
        preserveFolders = try values.decodeIfPresent(Bool.self, forKey: .preserveFolders) ?? false
        lockedIdentities = try values.decodeIfPresent([DraftAppIdentity].self, forKey: .lockedIdentities)
        deletionProtected = try values.decodeIfPresent(Set<String>.self, forKey: .deletionProtected) ?? []
        guard Set(rules.map(\.id)).count == rules.count,
            rules.allSatisfy({
                !$0.id.isEmpty && !$0.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.folder.count <= 60
                    && !$0.folder.contains("\0")
            })
        else {
            throw StudioError(L("The saved settings are invalid."))
        }
    }
}
struct Draft: Codable {
    var fingerprint: String
    var layout: Layout
    var identities: [DraftAppIdentity]? = nil
    var baselineLayout: Layout? = nil
    var syncConflict: Bool? = nil
}

final class StudioModel: ObservableObject {
    static var defaultDataRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
            "Launchpad Studio")
    }
    typealias ApplyOperation = (Layout, Snapshot, URL, BackupManager, String) throws -> BackupRecord
    @Published var baseline: Snapshot?
    @Published var layout = Layout(pages: [])
    @Published var apps: [AppRecord] = []
    @Published var selectedTab = "preview"
    @Published var settingsWindowActive = false
    @Published var selectedTile: String?
    @Published var selectedApp: Int64?
    @Published var pageIndex = 0
    @Published var search = ""
    @Published var error: String?
    @Published var notice = ""
    @Published var busy = false
    @Published var busyText = L("Backing up and applying to Launchpad…")
    @Published private(set) var draftNeedsSave = false
    @Published private(set) var preferencesNeedSave = false
    @Published var discoveryNeedsSave = false
    @Published private(set) var pendingRemovalReceipts: [UUID: RemovalReceipt] = [:]
    var hasUnsavedChanges: Bool {
        draftNeedsSave || preferencesNeedSave || discoveryNeedsSave || !pendingRemovalReceipts.isEmpty
    }
    var canEdit: Bool { baseline != nil && !busy }
    @Published var preferences = Preferences()
    @Published var backups: [BackupRecord] = []
    @Published var undoStack: [Layout] = []
    @Published var redoStack: [Layout] = []
    @Published var showApply = false
    @Published var restoreRecord: BackupRecord?
    @Published var showChanges = false
    @Published var pendingRestoreName: String?
    @Published var syncConflict = false
    var launchpadMonitor: LaunchpadMonitor?
    @Published var cleanupPanel: CleanupPanel?
    let dataRoot: URL
    let locateSource: () throws -> URL
    private let applyOperation: ApplyOperation
    private var settingsReady = false
    var backupManager: BackupManager?
    var source: URL?
    var icons: [Int64: NSImage] = [:]
    @Published var installedApplications: [InstalledApplication] = []
    @Published var discovery = AppDiscoveryState()
    @Published var newAppToast = false
    var waitingForNewAppRegistration = false
    @Published var inventoryIssue: String?
    @Published var removalTarget: InstalledApplication?
    @Published var removalPlan: RemovalPlan?
    @Published var removalScanning = false
    @Published var removalError: String?
    @Published var removalFailure: RemovalFailure?
    @Published var removalReceipt: RemovalReceipt?
    @Published var removalCompleted: [RemovalOutcome] = []
    @Published var removalSelection: Set<String> = []
    let removalScanner: RemovalScanner
    var applicationMonitor: ApplicationMonitor?
    var removalScanID = UUID()

    init(
        dataRoot: URL = StudioModel.defaultDataRoot,
        locateSource: @escaping () throws -> URL = LaunchpadStore.locate,
        applyOperation: @escaping ApplyOperation = LiveApply.apply,
        removalScanner: RemovalScanner = RemovalScanner()
    ) {
        self.dataRoot = dataRoot
        self.locateSource = locateSource
        self.applyOperation = applyOperation
        self.removalScanner = removalScanner
        do {
            try FileManager.default.createDirectory(
                at: dataRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try load(initial: true)
        } catch { self.error = error.localizedDescription }
        loadDiscovery()
    }
    var tile: Tile? { layout.tiles.first { $0.id == selectedTile } }
    var inspectedApp: AppRecord? {
        guard let tile else { return nil }
        let id = tile.isFolder ? selectedApp : tile.appIDs.first
        guard let id, tile.appIDs.contains(id) else { return nil }
        return app(id)
    }
    var folders: [Tile] { layout.tiles.filter(\.isFolder) }
    var changeCount: Int {
        guard let b = baseline else { return 0 }
        return apps.filter { layout.location($0.id) != b.layout.location($0.id) }.count
    }
    var hasChanges: Bool { baseline.map { $0.layout.semantic != layout.semantic } ?? false }
    var searchQuery: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    func matchesSearch(_ id: Int64) -> Bool {
        guard let app = app(id), !searchQuery.isEmpty else { return false }
        return app.name.localizedCaseInsensitiveContains(searchQuery)
            || app.bundleID.localizedCaseInsensitiveContains(searchQuery)
    }
    var previewTiles: [Tile] {
        if searchQuery.isEmpty { return layout.pages.indices.contains(pageIndex) ? layout.pages[pageIndex].tiles : [] }
        return layout.tiles.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery) || $0.appIDs.contains(where: matchesSearch)
        }
    }
    func selectTile(_ id: String) {
        guard let page = layout.pages.firstIndex(where: { $0.tiles.contains { $0.id == id } }),
            let tile = layout.pages[page].tiles.first(where: { $0.id == id })
        else { return }
        pageIndex = page
        selectedTile = id
        selectedApp = tile.isFolder ? tile.appIDs.first(where: matchesSearch) : tile.appIDs.first
    }
    func app(_ id: Int64) -> AppRecord? { apps.first { $0.id == id } }
    func icon(_ id: Int64) -> NSImage {
        if let icon = icons[id] { return icon }
        let icon: NSImage
        if let path = app(id)?.path {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else {
            icon = NSWorkspace.shared.icon(for: .applicationBundle)
        }
        icons[id] = icon
        return icon
    }
    func loadPreferences() throws {
        guard !settingsReady else { return }
        let url = dataRoot.appendingPathComponent("preferences.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { preferences = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url)) } catch {
                let recovered = try preserveFile(url, in: "Recovered Settings")
                self.error = L("The saved settings could not be loaded. A copy was kept at {0}.", recovered.path)
            }
        }
        settingsReady = true
    }
    func preserveFile(_ url: URL, in folder: String) throws -> URL {
        let root = dataRoot.appendingPathComponent(folder)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let recovered = root.appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: url, to: recovered)
        return recovered
    }
    func load(initial: Bool = false, preserving draft: Draft? = nil) throws {
        error = nil
        try loadPreferences()
        if backupManager == nil { backupManager = try BackupManager(root: dataRoot.appendingPathComponent("Backups")) }
        let restoreSavedDraft = initial || baseline == nil
        let newSource = try locateSource()
        let snapshot = try LaunchpadStore.snapshot(newSource.path)
        let paths = try Database(newSource.path).rows("SELECT item_id,hex(bookmark) AS data FROM apps")
        let newApps = snapshot.apps.map { original in
            var app = original
            if let hex = paths.first(where: { $0["item_id"] == String(app.id) })?["data"], !hex.isEmpty {
                var bytes = Data()
                var index = hex.startIndex
                while index < hex.endIndex {
                    let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
                    if let byte = UInt8(hex[index..<next], radix: 16) { bytes.append(byte) }
                    index = next
                }
                var stale = false
                if let url = try? URL(
                    resolvingBookmarkData: bytes, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                    bookmarkDataIsStale: &stale), FileManager.default.fileExists(atPath: url.path)
                {
                    app.path = url.path
                }
            }
            if app.path == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                app.path = url.path
            }
            return app
        }
        var restoredDraft: Layout?
        var conflict = false
        let draftURL = dataRoot.appendingPathComponent("draft.json")
        if let draft {
            restoredDraft = try draft.synchronized(for: snapshot, apps: newApps)
            conflict = try draft.needsSyncReview(for: snapshot, apps: newApps)
        } else if restoreSavedDraft, FileManager.default.fileExists(atPath: draftURL.path) {
            do {
                let saved = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: draftURL))
                restoredDraft = try saved.synchronized(for: snapshot, apps: newApps)
                conflict = try saved.needsSyncReview(for: snapshot, apps: newApps)
            } catch {
                // Preserve rejected or unreadable edits before replacing the active draft.
                let recovered = try preserveFile(draftURL, in: "Recovered Drafts")
                self.error = L("The saved draft could not be loaded. A copy was kept at {0}.", recovered.path)
            }
        }
        let keepHistory =
            draft != nil && baseline?.catalog == snapshot.catalog && restoredDraft?.semantic != snapshot.layout.semantic
        source = newSource
        baseline = snapshot
        apps = newApps
        icons = [:]
        syncConflict = conflict
        if let identities = preferences.lockedIdentities {
            preferences.locked = Set(
                identities.compactMap { identity in
                    apps.first { $0.uuid == identity.uuid && $0.bundleID == identity.bundleID }?.id
                })
        } else {
            preferences.locked.formIntersection(Set(apps.map(\.id)))
        }
        if !preferences.locked.isEmpty || preferences.lockedIdentities != nil { savePreferences() }
        if let restoredDraft {
            layout = restoredDraft
            notice = L("Draft loaded")
        } else if restoreSavedDraft {
            layout = Classifier.propose(
                apps: apps, rules: preferences.rules, current: snapshot.layout, locked: preferences.locked,
                preserveFolders: preferences.preserveFolders)
            notice = L("Apps loaded: {0}", apps.count)
        } else {
            layout = snapshot.layout
            notice = L("Layout refreshed")
        }
        selectedTile = layout.tiles.first?.id
        selectedApp = nil
        pageIndex = 0
        if !keepHistory {
            undoStack = []
            redoStack = []
        }
        pendingRestoreName = nil
        backups = backupManager?.list() ?? []
        saveDraft()
    }
    func savePreferences() {
        guard settingsReady else { return }
        preferences.lockedIdentities = apps.filter { preferences.locked.contains($0.id) }.map(DraftAppIdentity.init)
        do {
            try JSONEncoder().encode(preferences).write(
                to: dataRoot.appendingPathComponent("preferences.json"), options: .atomic)
            preferencesNeedSave = false
        } catch {
            preferencesNeedSave = true
            self.error = L("Could not save settings: {0}", error.localizedDescription)
        }
    }
    func saveDraft() {
        guard let baseline else { return }
        do {
            var draft = Draft(snapshot: baseline, layout: layout)
            draft.syncConflict = syncConflict
            try JSONEncoder().encode(draft).write(to: dataRoot.appendingPathComponent("draft.json"), options: .atomic)
            draftNeedsSave = false
        } catch {
            draftNeedsSave = true
            self.error = L("Could not save the draft: {0}", error.localizedDescription)
        }
    }
    func retryPendingSaves() -> Bool {
        if draftNeedsSave { saveDraft() }
        if preferencesNeedSave { savePreferences() }
        if discoveryNeedsSave { saveDiscovery() }
        retryRemovalReceiptSaves()
        return !hasUnsavedChanges
    }
    @discardableResult func retryRemovalReceiptSaves() -> Bool {
        for receipt in Array(pendingRemovalReceipts.values) { recordRemovalReceipt(receipt) }
        return pendingRemovalReceipts.isEmpty
    }
    @discardableResult func recordRemovalReceipt(_ receipt: RemovalReceipt) -> Bool {
        pendingRemovalReceipts[receipt.id] = receipt
        do {
            try RemovalHistory(root: dataRoot.appendingPathComponent("Removal History")).save(receipt)
            pendingRemovalReceipts.removeValue(forKey: receipt.id)
            return true
        } catch { return false }
    }
    func normalizeSelection() {
        pageIndex = min(max(0, pageIndex), max(0, layout.pages.count - 1))
        if let id = selectedTile, let page = layout.pages.firstIndex(where: { $0.tiles.contains { $0.id == id } }) {
            pageIndex = page
        } else {
            selectedTile = layout.pages.indices.contains(pageIndex) ? layout.pages[pageIndex].tiles.first?.id : nil
        }
        if let id = selectedApp, tile?.appIDs.contains(id) != true { selectedApp = nil }
    }
    func edit(_ action: (inout Layout) -> Void) {
        guard canEdit else { return }
        let before = layout
        action(&layout)
        guard layout != before else { return }
        undoStack.append(before)
        redoStack = []
        if undoStack.count > 50 { undoStack.removeFirst() }
        normalizeSelection()
        pendingRestoreName = nil
        saveDraft()
    }
    func undo() {
        guard canEdit, let previous = undoStack.popLast() else { return }
        redoStack.append(layout)
        layout = previous
        normalizeSelection()
        pendingRestoreName = nil
        saveDraft()
    }
    func redo() {
        guard canEdit, let next = redoStack.popLast() else { return }
        undoStack.append(layout)
        layout = next
        normalizeSelection()
        pendingRestoreName = nil
        saveDraft()
    }
    func classify() {
        guard !busy, baseline != nil else { return }
        edit { layout in
            layout = Classifier.propose(
                apps: apps, rules: preferences.rules, current: layout, locked: preferences.locked,
                preserveFolders: preferences.preserveFolders)
        }
        selectedTile = layout.tiles.first?.id
        selectedTab = "preview"
        pageIndex = 0
        search = ""
        notice = L("Auto-sort complete")
    }
    func resetDraft() {
        guard !busy, let baseline else { return }
        edit { $0 = baseline.layout }
        syncConflict = false
        saveDraft()
        selectedTile = layout.tiles.first?.id
        selectedApp = nil
        pageIndex = 0
        notice = L("Preview reset")
    }
    func rename(_ id: String, to name: String) {
        guard canEdit else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 60, !clean.contains("\0") else {
            error = L("Folder names must contain 1–60 characters.")
            return
        }
        edit { layout in
            for p in layout.pages.indices {
                if let t = layout.pages[p].tiles.firstIndex(where: { $0.id == id }) {
                    layout.pages[p].tiles[t].name = clean
                }
            }
        }
    }
    func createFolder() {
        guard canEdit else { return }
        let existing = Set(folders.map(\.name))
        var name = L("New Folder")
        var n = 2
        while existing.contains(name) {
            name = L("New Folder {0}", n)
            n += 1
        }
        let folder = Tile(name: name, appIDs: [], color: "teal")
        edit { layout in
            if layout.pages.isEmpty { layout.pages = [LayoutPage(tiles: [])] }
            let page = min(pageIndex, layout.pages.count - 1)
            if layout.pages[page].tiles.count < 35 {
                layout.pages[page].tiles.append(folder)
            } else {
                layout.pages.append(LayoutPage(tiles: [folder]))
            }
        }
        selectedTile = folder.id
        selectedApp = nil
        search = ""
        if let p = layout.pages.firstIndex(where: { $0.tiles.contains(where: { $0.id == folder.id }) }) {
            pageIndex = p
        }
    }
    func removeEmpty(_ id: String) {
        edit { layout in
            for p in layout.pages.indices {
                layout.pages[p].tiles.removeAll { $0.id == id && $0.isFolder && $0.appIDs.isEmpty }
            }
            layout.pages.removeAll { $0.tiles.isEmpty }
        }
    }
    func moveApps(_ ids: [Int64], to target: String) {
        guard canEdit else { return }
        var seen = Set<Int64>()
        let ids = ids.filter { app($0) != nil && seen.insert($0).inserted }
        guard !ids.isEmpty, target == "__root__" || folders.contains(where: { $0.id == target }) else { return }
        let focusedApp = selectedApp.flatMap { ids.contains($0) ? $0 : nil } ?? ids[0]
        edit { layout in
            let emptyFolders = Set(layout.tiles.filter { $0.isFolder && $0.appIDs.isEmpty }.map(\.id))
            for p in layout.pages.indices {
                for t in layout.pages[p].tiles.indices {
                    guard layout.pages[p].tiles[t].appIDs.contains(where: { seen.contains($0) }) else { continue }
                    layout.pages[p].tiles[t].remapApps { seen.contains($0) ? nil : $0 }
                }
                layout.pages[p].tiles.removeAll { !$0.isFolder && $0.appIDs.isEmpty }
            }
            if target == "__root__" {
                for id in ids {
                    if layout.pages.isEmpty || layout.pages.last!.tiles.count >= 35 {
                        layout.pages.append(LayoutPage(tiles: []))
                    }
                    layout.pages[layout.pages.count - 1].tiles.append(
                        Tile(id: "app-\(id)", name: app(id)?.name ?? L("App"), appIDs: [id], isFolder: false))
                }
            } else {
                for p in layout.pages.indices {
                    if let i = layout.pages[p].tiles.firstIndex(where: { $0.id == target }) {
                        layout.pages[p].tiles[i].appendApps(ids)
                    }
                }
            }
            for p in layout.pages.indices {
                layout.pages[p].tiles.removeAll {
                    $0.appIDs.isEmpty && $0.id != target && !emptyFolders.contains($0.id)
                }
            }
            layout.pages.removeAll { $0.tiles.isEmpty }
        }
        selectedTile = target == "__root__" ? "app-\(focusedApp)" : target
        selectedApp = focusedApp
        normalizeSelection()
        if !previewTiles.contains(where: { $0.id == selectedTile }) { search = "" }
        notice = L("Apps moved: {0}", ids.count)
        let reviewed =
            target == "__root__" ? [] : Set(ids.compactMap { app($0)?.bundleID }).intersection(discovery.pending)
        if !reviewed.isEmpty {
            discovery.pending.subtract(reviewed)
            saveDiscovery()
            if newApplications.isEmpty { newAppToast = false }
        }
    }
    func sortPageByName() {
        guard canEdit else { return }
        edit { layout in
            guard layout.pages.indices.contains(pageIndex) else { return }
            layout.pages[pageIndex].tiles.sort {
                if $0.name == $1.name { return $0.id < $1.id }
                return L10n.ordered($0.name, $1.name)
            }
        }
        notice = L("Sorted by name")
    }
    func reorderTile(_ id: String, by offset: Int) {
        edit { layout in
            for p in layout.pages.indices {
                if let i = layout.pages[p].tiles.firstIndex(where: { $0.id == id }),
                    layout.pages[p].tiles.indices.contains(i + offset)
                {
                    layout.pages[p].tiles.swapAt(i, i + offset)
                }
            }
        }
    }
    func moveTile(_ id: String, page: Int) {
        guard canEdit, page >= 0, page <= layout.pages.count else { return }
        edit { layout in
            guard let tile = layout.tiles.first(where: { $0.id == id }) else { return }
            guard !layout.pages.indices.contains(page) || !layout.pages[page].tiles.contains(where: { $0.id == id })
            else { return }
            if page == layout.pages.count { layout.pages.append(LayoutPage(tiles: [])) }
            guard layout.pages[page].tiles.count < 35 else {
                error = L("This page is full.")
                return
            }
            for p in layout.pages.indices { layout.pages[p].tiles.removeAll { $0.id == id } }
            layout.pages[page].tiles.append(tile)
            layout.pages.removeAll { $0.tiles.isEmpty }
        }
        if let p = layout.pages.firstIndex(where: { $0.tiles.contains(where: { $0.id == id }) }) {
            pageIndex = p
            selectedTile = id
            selectedApp = nil
        }
    }
    func reorderApp(_ id: Int64, in tileID: String, by offset: Int) {
        edit { layout in
            for p in layout.pages.indices {
                if let t = layout.pages[p].tiles.firstIndex(where: { $0.id == tileID }),
                    let a = layout.pages[p].tiles[t].appIDs.firstIndex(of: id),
                    layout.pages[p].tiles[t].appIDs.indices.contains(a + offset)
                {
                    layout.pages[p].tiles[t].appIDs.swapAt(a, a + offset)
                }
            }
        }
    }
    func lock(_ id: Int64) {
        guard !busy, app(id) != nil else { return }
        if preferences.locked.contains(id) { preferences.locked.remove(id) } else { preferences.locked.insert(id) }
        savePreferences()
    }
    func manualBackup() {
        guard !busy, let source, let manager = backupManager else { return }
        perform {
            _ = try manager.create(source: source, reason: "manual")
            self.backups = manager.list()
            self.notice = L("Backup saved")
        }
    }
    func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
    func apply() {
        guard !busy, baseline != nil, backupManager != nil else { return }
        reconcileLaunchpadCatalog()
        guard !syncConflict else {
            showApply = true
            return
        }
        guard let baseline = self.baseline, let source, let manager = backupManager else { return }
        showApply = false
        busyText = L("Backing up and applying to Launchpad…")
        busy = true
        let target = layout
        let operation = applyOperation
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try operation(target, baseline, source, manager, "before-apply") }
            DispatchQueue.main.async {
                defer { self.busy = false }
                self.backups = manager.list()
                switch result {
                case .success:
                    self.undoStack = []
                    self.redoStack = []
                    self.perform {
                        try self.load()
                        self.notice = L("Applied to Launchpad")
                    }
                case .failure(let error):
                    // A commit can succeed even if restarting or verifying Dock fails.
                    // Rebase the preview before the user retries; retain edits if the read fails.
                    if let latest = try? LaunchpadStore.snapshot(source.path),
                        latest.fingerprint != baseline.fingerprint
                    {
                        try? self.load(preserving: Draft(snapshot: baseline, layout: target))
                    }
                    self.error = error.localizedDescription
                }
            }
        }
    }
    func previewBackup(_ record: BackupRecord) {
        guard !busy, let manager = backupManager, let baseline, let source else { return }
        perform {
            let saved = try manager.read(record)
            guard record.sourcePath == source.resolvingSymlinksInPath().path else {
                throw StudioError(L("This backup belongs to another Mac or user."))
            }
            let restored = try Draft(snapshot: saved, layout: saved.layout).restored(for: baseline, apps: apps)
            edit { $0 = restored }
            selectedTile = layout.tiles.first?.id
            pageIndex = 0
            selectedTab = "preview"
            search = ""
            pendingRestoreName = L10n.date(record.date)
            notice = L("Backup loaded · Pending apply")
        }
    }
    func exportLayout() {
        guard !busy, let baseline else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Launchpad-layout.json"
        if panel.runModal() == .OK, let url = panel.url {
            perform {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(Draft(snapshot: baseline, layout: layout)).write(to: url, options: .atomic)
                notice = L("Layout exported")
            }
        }
    }
    func importLayout() {
        guard !busy, baseline != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            perform {
                guard let baseline else { return }
                let imported = try readDraft(from: url, baseline: baseline, apps: apps)
                edit { $0 = imported }
                selectedTile = layout.tiles.first?.id
                pageIndex = 0
                selectedTab = "preview"
                search = ""
                notice = L("Layout loaded · Pending apply")
            }
        }
    }
    func readDraft(from url: URL, baseline: Snapshot, apps: [AppRecord]) throws -> Layout {
        let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: url))
        return try draft.restored(for: baseline, apps: apps)
    }
}
