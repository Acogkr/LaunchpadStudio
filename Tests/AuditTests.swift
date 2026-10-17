import AppKit
import Darwin
import Foundation

func runAuditTests() throws {
    let fm = FileManager.default
    let root: URL
    if let i = CommandLine.arguments.firstIndex(of: "--test-directory"), CommandLine.arguments.count > i + 1 {
        root = URL(fileURLWithPath: CommandLine.arguments[i + 1]).appendingPathComponent(UUID().uuidString)
    } else {
        root = fm.temporaryDirectory.appendingPathComponent("LaunchpadAudit-" + UUID().uuidString)
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? fm.removeItem(at: root)
        L10n.testCode = nil
    }
    L10n.testCode = "en"
    var checks = 0
    func require(_ condition: Bool, _ message: String) throws { if !condition { throw StudioError(message) } }
    func check(_ condition: Bool, _ message: String) throws {
        try require(condition, message)
        checks += 1
        print("PASS \(checks): \(message)")
    }
    func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch {
            try check(true, message)
            return
        }
        throw StudioError("Expected rejection: " + message)
    }
    try check(
        [13, 14, 15].allSatisfy { PlatformSupport.supports(majorVersion: $0) },
        "The compatibility policy accepts macOS 13, 14, and 15")
    try check(
        [12, 16, 26, 27].allSatisfy { !PlatformSupport.supports(majorVersion: $0) },
        "Older, unknown, and post-Launchpad macOS versions are rejected")
    let userDraft = try? Data(contentsOf: StudioModel.defaultDataRoot.appendingPathComponent("draft.json"))
    let userPreferences = try? Data(contentsOf: StudioModel.defaultDataRoot.appendingPathComponent("preferences.json"))
    let live = try TestFixture.source()
    let liveBefore = try LaunchpadStore.snapshot(live.path)
    let fixture = root.appendingPathComponent("fixture.sqlite")
    try Database(live.path).snapshot(to: fixture)
    let baseline = try LaunchpadStore.snapshot(fixture.path)
    func model(_ name: String) throws -> StudioModel {
        let value = StudioModel(
            dataRoot: root.appendingPathComponent(name), locateSource: { fixture },
            applyOperation: { _, _, _, _, _ in throw StudioError("Unexpected live apply") })
        try require(value.error == nil, value.error ?? "Model initialization failed")
        return value
    }
    let seed = try model("retry")
    try require(!seed.folders.isEmpty && seed.apps.count > 36, "Audit fixture requires apps and folders")
    seed.rename(seed.folders[0].id, to: "Edits before a transient failure")
    let savedLayout = seed.layout
    var available = false
    let retry = StudioModel(
        dataRoot: seed.dataRoot,
        locateSource: {
            guard available else { throw StudioError("Temporarily unavailable") }
            return fixture
        })
    try check(retry.baseline == nil && retry.error != nil, "A failed initial connection leaves the saved draft intact")
    available = true
    try retry.load()
    try check(
        retry.layout == savedLayout && retry.error == nil,
        "Refresh after a failed startup restores edits instead of generating a new proposal")
    let originalFile = try Data(contentsOf: seed.dataRoot.appendingPathComponent("draft.json"))
    available = false
    try rejects("Failed refresh preserves the current draft and baseline") { try retry.load() }
    try check(
        retry.layout == savedLayout
            && (try Data(contentsOf: seed.dataRoot.appendingPathComponent("draft.json"))) == originalFile,
        "Connection failures cannot overwrite the saved draft")
    let backupBlockedRoot = root.appendingPathComponent("backup-unavailable")
    try fm.createDirectory(at: backupBlockedRoot, withIntermediateDirectories: true)
    try Data().write(to: backupBlockedRoot.appendingPathComponent("Backups"))
    let backupBlocked = StudioModel(dataRoot: backupBlockedRoot, locateSource: { fixture })
    try check(
        backupBlocked.baseline == nil && backupBlocked.backupManager == nil,
        "Unavailable backup storage cannot produce a falsely connected editor")
    try fm.removeItem(at: backupBlockedRoot.appendingPathComponent("Backups"))
    try backupBlocked.load()
    try check(
        backupBlocked.baseline != nil && backupBlocked.backupManager != nil && backupBlocked.error == nil,
        "Retry initializes backup storage after startup failure")

    let partial = try JSONDecoder().decode(Preferences.self, from: Data("{\"preserveFolders\":true}".utf8))
    try check(
        partial.preserveFolders && partial.rules.isEmpty && partial.locked.isEmpty,
        "Settings from older versions get defaults for absent fields")
    let badSettingsRoot = root.appendingPathComponent("bad-settings")
    try fm.createDirectory(at: badSettingsRoot, withIntermediateDirectories: true)
    let badSettings = Data("{broken settings".utf8)
    try badSettings.write(to: badSettingsRoot.appendingPathComponent("preferences.json"))
    let badModel = StudioModel(dataRoot: badSettingsRoot, locateSource: { fixture })
    let recoveredSettings = try fm.contentsOfDirectory(
        at: badSettingsRoot.appendingPathComponent("Recovered Settings"), includingPropertiesForKeys: nil)
    try check(
        badModel.baseline != nil && badModel.error != nil && recoveredSettings.count == 1
            && (try Data(contentsOf: recoveredSettings[0])) == badSettings,
        "Corrupt settings are preserved and reported instead of silently discarded")
    let pinRoot = root.appendingPathComponent("pins")
    try fm.createDirectory(at: pinRoot, withIntermediateDirectories: true)
    let pinApp = baseline.apps[0]
    var oldIdentity = pinApp
    oldIdentity.id = 9_999_991
    var pinPreferences = Preferences()
    pinPreferences.locked = [oldIdentity.id]
    pinPreferences.lockedIdentities = [DraftAppIdentity(oldIdentity)]
    try JSONEncoder().encode(pinPreferences).write(to: pinRoot.appendingPathComponent("preferences.json"))
    let pinned = try model("pins")
    try check(
        pinned.preferences.locked == [pinApp.id], "Pinned categories follow stable identities when app row IDs change")
    oldIdentity.id = pinApp.id
    oldIdentity.uuid = UUID().uuidString
    pinPreferences.locked = [pinApp.id]
    pinPreferences.lockedIdentities = [DraftAppIdentity(oldIdentity)]
    try JSONEncoder().encode(pinPreferences).write(to: pinRoot.appendingPathComponent("preferences.json"))
    try check(try model("pins").preferences.locked.isEmpty, "A new app cannot inherit a pin from a reused row ID")

    let writes = try model("write-errors")
    let draftPath = writes.dataRoot.appendingPathComponent("draft.json")
    try fm.moveItem(at: draftPath, to: writes.dataRoot.appendingPathComponent("original-draft.json"))
    try fm.createDirectory(at: draftPath, withIntermediateDirectories: false)
    writes.rename(writes.folders[0].id, to: "Keep this unsaved edit")
    try check(
        writes.draftNeedsSave && writes.hasUnsavedChanges && writes.layout.tiles[0].name == "Keep this unsaved edit",
        "A failed autosave retains the edit and marks it unsaved")
    try check(!writes.retryPendingSaves(), "Quitting cannot treat failed saves as successful")
    try fm.removeItem(at: draftPath)
    try check(
        writes.retryPendingSaves() && !writes.hasUnsavedChanges,
        "Autosave recovers after the filesystem becomes writable")
    try check(try model("write-errors").layout == writes.layout, "The retried save survives a new process model")
    let preferencesPath = writes.dataRoot.appendingPathComponent("preferences.json")
    try fm.createDirectory(at: preferencesPath, withIntermediateDirectories: false)
    writes.lock(writes.apps[0].id)
    try check(
        writes.preferencesNeedSave && !writes.retryPendingSaves(), "Failed setting writes are also tracked as unsaved")
    try fm.removeItem(at: preferencesPath)
    try check(
        writes.retryPendingSaves() && (try model("write-errors")).preferences.locked == writes.preferences.locked,
        "Settings and pins survive retrying a failed save")

    let ids = baseline.apps.map(\.id)
    let pages = try model("pages")
    let firstTile = Tile(name: "First page", appIDs: ids)
    let empty = Tile(name: "Temporary empty page", appIDs: [])
    pages.edit { $0 = Layout(pages: [LayoutPage(tiles: [firstTile]), LayoutPage(tiles: [empty])]) }
    pages.selectedTile = empty.id
    pages.pageIndex = 1
    pages.removeEmpty(empty.id)
    try check(
        pages.layout.pages.count == 1 && pages.pageIndex == 0 && pages.selectedTile == firstTile.id,
        "Deleting the last empty folder removes its empty page and repairs selection")
    pages.undo()
    try check(
        pages.layout.pages.count == 2 && pages.layout.tiles.contains { $0.id == empty.id },
        "Undo restores a removed empty page and folder")
    let beforeSamePage = pages.layout
    let historyCount = pages.undoStack.count
    pages.moveTile(firstTile.id, page: 0)
    try check(
        pages.layout == beforeSamePage && pages.undoStack.count == historyCount && pages.error == nil,
        "Moving to the same page is a harmless no-op")
    pages.moveTile(firstTile.id, page: pages.layout.pages.count)
    try check(
        pages.selectedTile == firstTile.id
            && pages.layout.pages[pages.pageIndex].tiles.contains { $0.id == firstTile.id },
        "Moving a folder to another page keeps the selection visible")
    pages.undo()
    try check(
        pages.layout.pages[pages.pageIndex].tiles.contains { $0.id == pages.selectedTile },
        "Undoing a page move follows the selected item back")
    pages.resetDraft()
    try check(
        pages.pageIndex == 0 && pages.selectedTile == pages.layout.pages.first?.tiles.first?.id,
        "Resetting a multipage draft returns to a valid first-page selection")
    var paginated = firstTile
    paginated.pageSizes = [1] + stride(from: 1, to: ids.count, by: 35).map { min(35, ids.count - $0) }
    let paginatedLayout = Layout(pages: [LayoutPage(tiles: [paginated, empty])])
    let kept = Classifier.propose(
        apps: baseline.apps, rules: [], current: paginatedLayout, locked: [], preserveFolders: true)
    try check(
        kept.tiles == paginatedLayout.tiles,
        "Keep Existing Folders preserves internal pages and deliberately empty folders")
    var smallPages = Tile(name: "Sparse pages", appIDs: Array(ids.prefix(4)), pageSizes: [1, 3])
    smallPages.remapApps { $0 == ids[2] ? nil : $0 }
    try check(
        smallPages.pageSizes == [1, 2] && smallPages.appIDs == [ids[0], ids[1], ids[3]],
        "Removing an app preserves the remaining apps' folder pages")
    smallPages.appendApps([ids[4], ids[5]])
    try check(
        smallPages.pageSizes == [1, 4], "Adding apps fills the last folder page without collapsing earlier pages")
    var keepBeforeInstall = paginated
    keepBeforeInstall.remapApps { $0 == ids.last! ? nil : $0 }
    let loose = Tile(id: "app-\(ids.last!)", name: baseline.apps.last!.name, appIDs: [ids.last!], isFolder: false)
    let classifyExtra = Classifier.propose(
        apps: baseline.apps, rules: [Rule(keyword: loose.name, folder: keepBeforeInstall.name)],
        current: Layout(pages: [LayoutPage(tiles: [keepBeforeInstall, loose])]), locked: [], preserveFolders: true)
    try check(
        classifyExtra.tiles.first?.pageSizes.first == 1 && classifyExtra.appIDs.count == ids.count,
        "Auto-sorting a new app into a kept folder preserves earlier page boundaries")

    let implicit = Layout(pages: [LayoutPage(tiles: [firstTile])])
    let db = try Database(fixture.path, writable: true)
    try db.execute("BEGIN IMMEDIATE")
    try LaunchpadStore.write(implicit, to: db, baseline: baseline)
    try check(
        try LaunchpadStore.read(db).layout.semantic == implicit.semantic,
        "Large imported folders with implicit pagination round-trip through the writer")
    try db.execute("ROLLBACK")
    var malformed = implicit
    malformed.pages[0].tiles[0].pageSizes = [Int.max, Int.max]
    try rejects("Extreme imported page sizes cannot overflow or crash validation") {
        try malformed.validated(for: baseline.apps, purpose: .draft)
    }
    malformed = paginatedLayout
    malformed.pages[0].tiles[1].id = malformed.pages[0].tiles[0].id
    try rejects("Duplicate tile identities are rejected before reaching SwiftUI") {
        try malformed.validated(for: baseline.apps, purpose: .draft)
    }
    malformed = implicit
    malformed.pages.append(LayoutPage(id: malformed.pages[0].id, tiles: []))
    try rejects("Duplicate page identities are rejected") {
        try malformed.validated(for: baseline.apps, purpose: .draft)
    }
    malformed = implicit
    malformed.pages[0].tiles[0].name = "Invalid\0name"
    try rejects("Embedded null characters cannot truncate saved folder names") {
        try malformed.validated(for: baseline.apps, purpose: .draft)
    }
    var special = implicit
    special.pages[0].tiles[0].name = "Folder:\n---PAGE---\n[1] '한글'"
    try db.execute("BEGIN IMMEDIATE")
    try LaunchpadStore.write(special, to: db, baseline: baseline)
    try check(
        try LaunchpadStore.read(db).layout.semantic == special.semantic,
        "Delimiter-like Unicode folder names round-trip without ambiguous layout comparisons")
    try db.execute("ROLLBACK")
    try db.execute("BEGIN IMMEDIATE")
    try db.execute("UPDATE items SET ordering='broken' WHERE rowid=?", [String(ids[0])])
    try rejects("Malformed database ordering is rejected without forced-unwrapping crashes") {
        _ = try LaunchpadStore.read(db)
    }
    try db.execute("ROLLBACK")

    // A backup from before installation still contains the other apps' stable identities.
    let backupModel = try model("backup-catalog")
    let manager = backupModel.backupManager!
    let currentBackup = try manager.create(source: fixture, reason: "audit")
    try db.execute("BEGIN IMMEDIATE")
    try db.execute("UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers'")
    try db.execute("UPDATE items SET parent_id=? WHERE rowid=?", [String(baseline.holding), String(ids.last!)])
    try db.execute("UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers'")
    try db.execute("COMMIT")
    let olderBackup = try manager.create(source: fixture, reason: "audit before installation")
    // Restore the original fixture through the same checked writer.
    let hiddenSnapshot = try LaunchpadStore.snapshot(fixture.path)
    try db.execute("BEGIN IMMEDIATE")
    try db.execute("UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers'")
    let originalRow = baseline.allRows.first { $0["rowid"] == String(ids.last!) }!
    try db.execute(
        "UPDATE items SET parent_id=?,ordering=? WHERE rowid=?",
        [originalRow["parent_id"], originalRow["ordering"], String(ids.last!)])
    try db.execute("UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers'")
    try db.execute("COMMIT")
    _ = hiddenSnapshot
    try backupModel.load()
    backupModel.previewBackup(olderBackup)
    try check(
        backupModel.error == nil && Set(backupModel.layout.appIDs) == Set(ids)
            && backupModel.layout.appIDs.count == ids.count,
        "A pre-installation backup loads with newly installed apps kept exactly once")
    try check(
        backupModel.layout.tiles.last?.appIDs == [ids.last!], "New apps are added after the restored backup arrangement"
    )
    var wrongUser = currentBackup
    wrongUser.sourcePath = "/another-user/Launchpad/db"
    let beforeWrongUser = backupModel.layout
    backupModel.previewBackup(wrongUser)
    try check(
        backupModel.error != nil && backupModel.layout == beforeWrongUser,
        "Backups from a different user cannot overwrite the preview")

    let failFixture = root.appendingPathComponent("post-commit.sqlite")
    try Database(live.path).snapshot(to: failFixture)
    let postCommit = StudioModel(
        dataRoot: root.appendingPathComponent("post-commit"), locateSource: { failFixture },
        applyOperation: { layout, before, source, backups, reason in
            let _ = try backups.create(source: source, reason: reason)
            let transaction = try Database(source.path, writable: true)
            try transaction.execute("BEGIN IMMEDIATE")
            do {
                try LaunchpadStore.write(layout, to: transaction, baseline: before)
                try transaction.execute("COMMIT")
            } catch {
                try? transaction.execute("ROLLBACK")
                throw error
            }
            throw StudioError("Simulated Dock verification failure after commit")
        })
    postCommit.rename(postCommit.folders[0].id, to: "Committed before verification failed")
    let target = postCommit.layout
    postCommit.apply()
    let deadline = Date().addingTimeInterval(10)
    while postCommit.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    try check(
        !postCommit.busy && postCommit.error != nil && postCommit.layout.semantic == target.semantic
            && !postCommit.hasChanges,
        "A post-commit verification failure refreshes the baseline without losing the applied draft")
    try check(
        postCommit.undoStack.isEmpty
            && postCommit.baseline?.fingerprint == (try LaunchpadStore.snapshot(failFixture.path)).fingerprint,
        "Retry cannot accidentally use the pre-commit database fingerprint")

    var session: SessionLock? = try SessionLock(directory: root.appendingPathComponent("session"))
    try check(
        session != nil && (try SessionLock(directory: root.appendingPathComponent("session"))) == nil,
        "Two app instances cannot acquire the same draft session")
    session = nil
    let nextSession = try SessionLock(directory: root.appendingPathComponent("session"))
    try check(nextSession != nil, "Closing an instance releases the session lock")
    try rejects("The crash watchdog rejects unsafe process identifiers") {
        _ = try ApplyWatchdog.start(owner: 0, target: -1)
    }
    let owner = Process()
    let paused = Process()
    owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
    owner.arguments = ["60"]
    paused.executableURL = URL(fileURLWithPath: "/bin/sleep")
    paused.arguments = ["60"]
    try owner.run()
    try paused.run()
    let watchdog = try ApplyWatchdog.start(owner: owner.processIdentifier, target: paused.processIdentifier)
    defer {
        if paused.isRunning {
            kill(paused.processIdentifier, SIGCONT)
            paused.terminate()
        }
        if owner.isRunning { owner.terminate() }
        if watchdog.isRunning { watchdog.terminate() }
    }
    func state(_ pid: Int32) throws -> String {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", String(pid), "-o", "state="]
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    kill(paused.processIdentifier, SIGSTOP)
    Thread.sleep(forTimeInterval: 13)
    try check(
        try state(paused.processIdentifier).contains("T"),
        "A slow operation stays paused beyond the old 12-second watchdog deadline")
    kill(owner.processIdentifier, SIGKILL)
    owner.waitUntilExit()
    let resumeDeadline = Date().addingTimeInterval(4)
    while try state(paused.processIdentifier).contains("T") && Date() < resumeDeadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    try check(
        try !state(paused.processIdentifier).contains("T"),
        "If the owner exits unexpectedly, the watchdog resumes only the disposable target process")

    var randomState: UInt64 = 0xC0DE_51A7
    func random(_ count: Int) -> Int {
        randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
        return count > 0 ? Int((randomState >> 32) % UInt64(count)) : 0
    }
    var stress = try model("stress")
    for step in 0..<1500 {
        stress.error = nil
        switch random(12) {
        case 0: stress.createFolder()
        case 1:
            let targets = stress.folders.map(\.id) + ["__root__"]
            let id = stress.apps[random(stress.apps.count)].id
            stress.moveApps([id, id], to: targets[random(targets.count)])
        case 2:
            if !stress.folders.isEmpty {
                stress.rename(stress.folders[random(stress.folders.count)].id, to: "검사 \(step) / 日本語 / 中文")
            }
        case 3:
            let all = stress.layout.tiles
            if !all.isEmpty { stress.moveTile(all[random(all.count)].id, page: random(stress.layout.pages.count + 1)) }
        case 4: stress.sortPageByName()
        case 5:
            if !stress.undoStack.isEmpty {
                let before = stress.layout
                stress.undo()
                stress.redo()
                try require(stress.layout == before, "Stress undo/redo mismatch at step \(step)")
            }
        case 6:
            let before = stress.layout
            stress = try model("stress")
            try require(stress.layout == before, "Stress restart mismatch at step \(step)")
        case 7:
            stress.preferences.preserveFolders = random(2) == 0
            stress.savePreferences()
            stress.classify()
        case 8: if let tile = stress.folders.first(where: { $0.appIDs.isEmpty }) { stress.removeEmpty(tile.id) }
        case 9: stress.resetDraft()
        case 10: stress.lock(stress.apps[random(stress.apps.count)].id)
        default:
            let tiles = stress.layout.tiles
            if !tiles.isEmpty { stress.reorderTile(tiles[random(tiles.count)].id, by: random(2) == 0 ? -1 : 1) }
        }
        try stress.layout.validated(for: stress.apps, purpose: .draft)
        try require(stress.layout.pages.indices.contains(stress.pageIndex), "Invalid page at stress step \(step)")
        if let selected = stress.selectedTile {
            try require(
                stress.layout.pages[stress.pageIndex].tiles.contains { $0.id == selected },
                "Invisible selection at stress step \(step)")
        }
        try require(!stress.hasUnsavedChanges, "Unpersisted stress draft at step \(step)")
    }
    try check(
        true,
        "1,500 deterministic mixed edits, undo/redo, restarts, classification, pins, and page moves preserve layout and selection invariants"
    )
    try check(
        (try? Data(contentsOf: StudioModel.defaultDataRoot.appendingPathComponent("draft.json"))) == userDraft
            && (try? Data(contentsOf: StudioModel.defaultDataRoot.appendingPathComponent("preferences.json")))
                == userPreferences,
        "The full audit leaves real user drafts and settings unchanged")
    try check(
        try LaunchpadStore.snapshot(live.path).fingerprint == liveBefore.fingerprint,
        "The source database is unchanged by all audit scenarios")
    print(
        "SUCCESS: \(checks) full-audit checks passed, including 1,500 mixed operations and disposable-process watchdog tests. Actual Dock was never signalled."
    )
}
