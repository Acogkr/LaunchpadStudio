import AppKit
import Carbon

func runCleanupTests() throws {
    L10n.testCode = "en"
    let fm = FileManager.default
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
        "StudioCleanup-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? fm.removeItem(at: root)
        L10n.testCode = nil
    }
    var checks = 0
    func check(_ value: @autoclosure () throws -> Bool, _ description: String) throws {
        guard try value() else { throw StudioError(description) }
        checks += 1
        print("PASS \(checks): \(description)")
    }
    func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch {
            try check(true, message)
            return
        }
        throw StudioError("Expected rejection: " + message)
    }
    func file(_ url: URL, _ text: String = "original data") throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    let source = root.appendingPathComponent("source.sqlite")
    try Database(TestFixture.source().path).snapshot(to: source)
    let data = root.appendingPathComponent("Data")
    var applyCalls = 0
    let model = StudioModel(
        dataRoot: data, locateSource: { source },
        applyOperation: { _, _, _, _, _ in
            applyCalls += 1
            throw StudioError("Test apply")
        })
    try model.load()
    let db = try Database(source.path, writable: true)
    let folder = model.folders.first!
    let folderID = String(folder.id.dropFirst("folder-".count))
    model.rename(folder.id, to: "Redo after installation")
    model.undo()
    try makeFixturePage(db, id: 900091)
    try db.execute("INSERT INTO items VALUES (900090,'REDO-NEW-APP',0,4,900091,0)")
    try db.execute("INSERT INTO apps VALUES (900090,'Redo New App','org.example.redo-new',NULL,3,0,NULL)")
    model.reconcileLaunchpadCatalog()
    try check(
        !model.hasChanges && !model.redoStack.isEmpty, "Installing an app after undoing all edits retains redo history")
    model.redo()
    try check(
        model.layout.appIDs.contains(900090)
            && model.folders.first { $0.id == folder.id }?.name == "Redo after installation",
        "Redo after installation preserves the new app and restores the edit")
    model.undo()
    try db.execute("DELETE FROM items WHERE rowid=900090")
    model.reconcileLaunchpadCatalog()
    try check(
        !model.redoStack.isEmpty && model.redoStack.allSatisfy { !$0.appIDs.contains(900090) },
        "Uninstallation rebases redo history without restoring a missing app")
    try db.execute("UPDATE groups SET title=? WHERE item_id=?", ["External arrangement", folderID])
    model.receiveApplications([])
    try check(model.redoStack.isEmpty, "Adopting an external arrangement clears incompatible redo history")
    try check(
        model.layout.semantic == model.baseline?.layout.semantic && !model.hasChanges && !model.syncConflict,
        "Unedited previews immediately follow external Launchpad edits")
    try check(
        model.folders.first { $0.id == folder.id }?.name == "External arrangement",
        "External folder names are not overwritten by a stale preview")
    model.rename(folder.id, to: "My edits")
    try db.execute("UPDATE groups SET title=? WHERE item_id=?", ["Another external edit", folderID])
    model.receiveApplications([])
    try check(
        model.syncConflict && model.folders.first { $0.id == folder.id }?.name == "My edits",
        "Competing edits preserve the draft and require a decision")
    model.apply()
    try check(applyCalls == 0 && model.showApply && !model.busy, "A sync conflict cannot reach the write operation")
    let reopened = StudioModel(dataRoot: data, locateSource: { source })
    try check(
        reopened.syncConflict && reopened.folders.first { $0.id == folder.id }?.name == "My edits",
        "An unresolved conflict survives relaunch")
    reopened.resolveSyncConflict(keepEdits: true)
    try check(!reopened.syncConflict && reopened.hasChanges, "Keeping edits clears only the conflict, not the draft")
    let accepted = StudioModel(dataRoot: data, locateSource: { source })
    try check(!accepted.syncConflict && accepted.hasChanges, "An explicit choice survives relaunch")
    accepted.resolveSyncConflict(keepEdits: false)
    try check(
        !accepted.hasChanges && accepted.folders.first { $0.id == folder.id }?.name == "Another external edit",
        "Choosing Launchpad adopts the external layout")
    try db.execute("UPDATE groups SET title=? WHERE item_id=?", ["Changed while closed", folderID])
    let cleanReopen = StudioModel(dataRoot: data, locateSource: { source })
    try check(
        !cleanReopen.hasChanges && cleanReopen.folders.first { $0.id == folder.id }?.name == "Changed while closed",
        "Clean saved drafts follow changes made while the app was closed")
    cleanReopen.rename(folder.id, to: "Offline edits")
    try db.execute("UPDATE groups SET title=? WHERE item_id=?", ["Offline external", folderID])
    let dirtyReopen = StudioModel(dataRoot: data, locateSource: { source })
    try check(
        dirtyReopen.syncConflict && dirtyReopen.folders.first { $0.id == folder.id }?.name == "Offline edits",
        "Offline conflicts are detected from the saved baseline")
    dirtyReopen.resetDraft()
    try check(!dirtyReopen.hasChanges && !dirtyReopen.syncConflict, "Reset to current layout resolves a conflict")
    dirtyReopen.rename(folder.id, to: "Keep across install")
    try db.execute("INSERT INTO items VALUES (900050,'CLEANUP-NEW-APP',0,4,900091,0)")
    try db.execute("INSERT INTO apps VALUES (900050,'New App','org.example.cleanup-new',NULL,3,0,NULL)")
    dirtyReopen.receiveApplications([])
    try check(
        !dirtyReopen.syncConflict && dirtyReopen.layout.appIDs.contains(900050)
            && dirtyReopen.folders.first { $0.id == folder.id }?.name == "Keep across install",
        "Catalog additions preserve edits without false conflicts")
    try db.execute("DELETE FROM items WHERE rowid=900050")
    dirtyReopen.receiveApplications([])
    try check(
        !dirtyReopen.syncConflict && !dirtyReopen.layout.appIDs.contains(900050),
        "Catalog removals preserve edits without false conflicts")
    try db.execute("INSERT INTO items VALUES (900060,'EMPTY-FOLDER-PAGE',0,3,?,5)", [folderID])
    try db.execute("INSERT INTO groups VALUES (900060,NULL,NULL)")
    dirtyReopen.reconcileLaunchpadCatalog()
    try check(
        !dirtyReopen.syncConflict && dirtyReopen.folders.first { $0.id == folder.id }?.name == "Keep across install",
        "Empty folder pages cannot stall catalog synchronization")
    try db.execute("UPDATE groups SET title=? WHERE item_id=?", ["Rename with an empty page", folderID])
    dirtyReopen.reconcileLaunchpadCatalog()
    try check(dirtyReopen.syncConflict, "External edits are detected even when Dock contains an empty folder page")
    var legacyDraft = Draft(snapshot: dirtyReopen.baseline!, layout: dirtyReopen.layout)
    legacyDraft.baselineLayout?.pages[0].tiles[0].pageSizes.append(0)
    legacyDraft.fingerprint = "legacy-empty-page"
    try check(
        try !legacyDraft.needsSyncReview(for: dirtyReopen.baseline!, apps: dirtyReopen.apps),
        "Legacy baseline metadata with empty pages remains readable")
    try db.execute("DELETE FROM items WHERE rowid=900060")
    var ready = false
    let recovery = StudioModel(
        dataRoot: root.appendingPathComponent("Recovery"),
        locateSource: {
            if !ready { throw StudioError("Not ready") }
            return source
        })
    ready = true
    recovery.receiveApplications([])
    try check(
        recovery.baseline != nil && recovery.error == nil,
        "An initial read failure recovers through the automatic inventory callback")
    try recovery.load()
    let monitor = LaunchpadMonitor(model: recovery)
    monitor.start()
    defer { monitor.stop() }
    try db.execute("UPDATE groups SET title=? WHERE item_id=?", ["Watched update", folderID])
    let deadline = Date().addingTimeInterval(6)
    while recovery.folders.first(where: { $0.id == folder.id })?.name != "Watched update" && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    try check(
        recovery.folders.first { $0.id == folder.id }?.name == "Watched update",
        "Database or WAL changes synchronize without an application-folder event")
    recovery.busy = true
    try db.execute("UPDATE groups SET title=? WHERE item_id=?", ["Deferred update", folderID])
    monitor.refresh(force: true)
    try check(
        recovery.folders.first { $0.id == folder.id }?.name == "Watched update",
        "Synchronization waits while an operation is busy")
    recovery.busy = false
    monitor.refresh()
    try check(
        recovery.folders.first { $0.id == folder.id }?.name == "Deferred update",
        "A deferred database update is retried")
    monitor.stop()

    let oldPath = root.appendingPathComponent("old-location.sqlite")
    let newPath = root.appendingPathComponent("new-location.sqlite")
    try Database(source.path).snapshot(to: oldPath)
    var currentPath = oldPath
    let relocatedModel = StudioModel(dataRoot: root.appendingPathComponent("Relocated"), locateSource: { currentPath })
    try relocatedModel.load()
    try fm.moveItem(at: oldPath, to: newPath)
    currentPath = newPath
    // A moved WAL database needs its sidecars initialized by a writer, as Dock does.
    // Read-only SQLite cannot initialize them at a brand-new path on macOS.
    let relocatedWriter = try Database(newPath.path, writable: true)
    _ = try LaunchpadStore.read(relocatedWriter)
    _ = withExtendedLifetime(relocatedWriter) { relocatedModel.reconcileLaunchpadCatalog() }
    try check(
        relocatedModel.source == newPath && !relocatedModel.hasChanges,
        "A replaced database is rediscovered even when its contents are unchanged (relocated: \(relocatedModel.source == newPath), edits: \(relocatedModel.hasChanges), error: \(relocatedModel.error ?? "none"))")
    var oldDiscovery = try JSONDecoder().decode(
        AppDiscoveryState.self, from: Data("{\"initialized\":true,\"known\":[],\"pending\":[]}".utf8))
    try check(oldDiscovery.names == nil, "Old discovery history decodes without app names")

    let applications = root.appendingPathComponent("Applications")
    let library = root.appendingPathComponent("Library")
    let trash = root.appendingPathComponent("Trash")
    try fm.createDirectory(at: trash, withIntermediateDirectories: true)
    let app = try makeFixtureApplication(applications, name: "Notes", bundleID: "org.example.cleanup-notes")
    let scanner = RemovalScanner(
        applicationRoots: [applications], libraryRoots: [library], registeredApplications: { _ in [] })
    let interruptedApp = try makeFixtureApplication(
        applications, name: "Journal Failure", bundleID: "org.example.journal-failure")
    let interruptedPrefs = library.appendingPathComponent("Preferences/" + interruptedApp.bundleID + ".plist")
    try file(interruptedPrefs)
    let interruptedPlan = try scanner.scan(interruptedApp)
    var earlyInterruption: RemovalHistoryWriteError?
    var earlyMoves = 0
    do {
        _ = try finishAsync {
            try await ApplicationRemoval.execute(
                interruptedPlan, selected: Set(interruptedPlan.candidates.map(\.id)), scanner: scanner,
                running: { _ in false },
                recycle: { url in
                    earlyMoves += 1
                    return url
                },
                checkpoint: { _ in throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) })
        }
    } catch { earlyInterruption = error as? RemovalHistoryWriteError }
    try check(
        earlyInterruption != nil && earlyMoves == 0 && fm.fileExists(atPath: interruptedApp.path),
        "An unwritable initial journal is reported as a history failure before any file moves")
    var interruption: RemovalHistoryWriteError?
    do {
        _ = try finishAsync {
            try await ApplicationRemoval.execute(
                interruptedPlan, selected: Set(interruptedPlan.candidates.map(\.id)), scanner: scanner,
                running: { _ in false },
                recycle: { url in
                    let destination = trash.appendingPathComponent(url.lastPathComponent)
                    try fm.moveItem(at: url, to: destination)
                    return destination
                },
                checkpoint: { receipt in
                    if !receipt.items.isEmpty {
                        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
                    }
                })
        }
    } catch { interruption = error as? RemovalHistoryWriteError }
    try check(
        interruption?.receipt.items.contains { $0.originalPath == interruptedApp.path && $0.trashPath != nil } == true,
        "A journal failure after moving the app preserves its completed Trash result")
    try check(
        fm.fileExists(atPath: interruptedPrefs.path) && interruption?.receipt.hasFailures == true,
        "A journal failure stops further file moves and records the unattempted remainder")
    let interruptedReceipt = interruption!.receipt
    let journalModel = StudioModel(
        dataRoot: root.appendingPathComponent("Journal Model"), locateSource: { source }, removalScanner: scanner)
    let blockedHistory = journalModel.dataRoot.appendingPathComponent("Removal History")
    try file(blockedHistory)
    journalModel.removalTarget = interruptedApp
    journalModel.removalPlan = interruptedPlan
    journalModel.showRemovalResult(interruptedReceipt, issue: interruption!.localizedDescription)
    try check(
        journalModel.removalReceipt?.items.count == 2 && journalModel.removalError != nil
            && journalModel.hasUnsavedChanges,
        "The removal screen retains partial results and an unsaved receipt when history remains unwritable")
    try check(
        journalModel.removalFailure == nil && journalModel.removalAccessIssue == nil,
        "A history write error is not misreported as missing app-management or Finder permission")
    journalModel.closeRemoval()
    try check(
        journalModel.pendingRemovalReceipts.count == 1 && !journalModel.retryPendingSaves(),
        "Closing the removal sheet cannot silently discard an unsaved Trash receipt")
    try fm.removeItem(at: blockedHistory)
    try check(
        journalModel.retryPendingSaves() && !journalModel.hasUnsavedChanges,
        "Restoring write access allows the pending receipt to be saved before quitting")
    let recoveredHistory = try RemovalHistory(root: blockedHistory).load()
    try check(
        recoveredHistory.first?.items.first?.trashPath == interruptedReceipt.items.first?.trashPath
            && recoveredHistory.first?.items.count == 2,
        "The recovered history retains the original Trash location and the unattempted files")
    var retryMoves = 0
    let completedJournal = try finishAsync {
        try await ApplicationRemoval.execute(
            interruptedPlan, selected: Set(interruptedPlan.candidates.map(\.id)), scanner: scanner,
            running: { _ in false },
            recycle: { url in
                retryMoves += 1
                let destination = trash.appendingPathComponent(url.lastPathComponent)
                try fm.moveItem(at: url, to: destination)
                return destination
            }, previous: interruptedReceipt.items, checkpoint: RemovalHistory(root: blockedHistory).save)
    }
    try check(
        retryMoves == 1 && !completedJournal.hasFailures && completedJournal.items.count == 2,
        "Retry after a journal failure moves only the previously unattempted file")
    _ = oldDiscovery.reconcile([app])
    try check(
        oldDiscovery.names?[app.bundleID] == app.name, "Discovery retains app names for readable leftover results")
    let cache = library.appendingPathComponent("Caches/" + app.bundleID)
    let preferences = library.appendingPathComponent("Preferences/" + app.bundleID + ".plist")
    try file(cache.appendingPathComponent("cache.bin"))
    try file(preferences)
    let history = RemovalHistory(root: root.appendingPathComponent("History"))
    let plan = try scanner.scan(app)
    var guarded = scanner
    guarded.deletionProtected = [app.bundleID]
    try rejects("Deletion protection is enforced by the scanner") { _ = try guarded.scan(app) }
    try rejects("Deletion protection also blocks an already prepared plan") {
        _ = try finishAsync {
            try await ApplicationRemoval.execute(plan, selected: [app.path], scanner: guarded, running: { _ in false })
        }
    }
    try check(fm.fileExists(atPath: app.path), "A protected app remains installed")
    let prefsModel = StudioModel(
        dataRoot: root.appendingPathComponent("Protection"), locateSource: { source }, removalScanner: scanner)
    prefsModel.toggleDeletionProtection(app.bundleID)
    prefsModel.prepareRemoval(app)
    try check(
        prefsModel.removalTarget == nil && prefsModel.preferences.locked.isEmpty,
        "Deletion protection blocks the UI without changing classification pins")
    let prefsReloaded = StudioModel(dataRoot: prefsModel.dataRoot, locateSource: { source }, removalScanner: scanner)
    try check(prefsReloaded.isDeletionProtected(app.bundleID), "Deletion protection persists by bundle identifier")
    let legacyPreferences = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
    try check(legacyPreferences.deletionProtected.isEmpty, "Older preferences remain readable")
    let move: ApplicationRemoval.Recycle = { url in
        let destination = trash.appendingPathComponent(url.lastPathComponent)
        try fm.moveItem(at: url, to: destination)
        return destination
    }
    var checkpoints = 0
    let receipt = try finishAsync {
        try await ApplicationRemoval.execute(
            plan, selected: Set(plan.candidates.map(\.id)), scanner: scanner, running: { _ in false }, recycle: move,
            checkpoint: { receipt in
                try history.save(receipt)
                checkpoints += 1
            })
    }
    try check(
        !receipt.hasFailures && receipt.items.count == 3 && checkpoints == 4,
        "Each moved file has a durable deletion record")
    try check(
        receipt.items.allSatisfy { $0.kind != nil && $0.trashStamp != nil } && receipt.bundleID == app.bundleID,
        "Deletion records include ownership and actual Trash identities")
    let damagedRecord = history.root.appendingPathComponent(UUID().uuidString + ".json")
    let damagedData = Data("{incomplete receipt".utf8)
    try damagedData.write(to: damagedRecord)
    try check(try history.load().count == 1, "A damaged receipt cannot hide valid deletion history")
    try check(
        try history.read().unreadableCount == 1, "Unreadable history is reported instead of silently disappearing")
    try check(
        try Data(contentsOf: damagedRecord) == damagedData, "Reading damaged history preserves the original record")
    let entries = try history.entries()
    let restore = TrashRestore(scanner: scanner, trashRoots: [trash])
    let appEntry = entries.first { $0.item.kind == .application }!
    try check(
        try restore.validate(appEntry).1 == app.url, "A verified app in Trash can be restored to its original location")
    var legacyItem = appEntry.item
    legacyItem.trashStamp = nil
    let legacyEntry = HistoryEntry(receipt: receipt, item: legacyItem)
    try rejects("Legacy path-only receipts cannot restore an unverified item") { _ = try restore.validate(legacyEntry) }
    let legacyData = Data("{\"originalPath\":\"/Applications/Old.app\",\"trashPath\":\"/tmp/Old.app\"}".utf8)
    try check(
        try JSONDecoder().decode(RemovalOutcome.self, from: legacyData).trashStamp == nil,
        "Old deletion records decode without a migration failure")
    let cacheEntry = entries.first { $0.item.kind == .cache }!
    let cacheTrash = URL(fileURLWithPath: cacheEntry.item.trashPath!)
    let displaced = root.appendingPathComponent("Original Cache")
    try fm.moveItem(at: cacheTrash, to: displaced)
    try file(cacheTrash.appendingPathComponent("replacement.bin"))
    try rejects("A same-name replacement in Trash cannot be restored") { _ = try restore.validate(cacheEntry) }
    try fm.removeItem(at: cacheTrash)
    try fm.moveItem(at: displaced, to: cacheTrash)
    try file(cache.appendingPathComponent("existing.bin"))
    try rejects("Restore never overwrites an existing destination") { _ = try restore.validate(cacheEntry) }
    try check(
        fm.fileExists(atPath: cache.appendingPathComponent("existing.bin").path),
        "Destination collision leaves existing data untouched")
    try fm.removeItem(at: cache)
    let prefsEntry = entries.first { $0.item.kind == .preferences }!
    var badReceipt = receipt
    badReceipt.bundleID = "org.unrelated.app"
    try rejects("A receipt cannot claim another app's preference path") {
        _ = try restore.validate(HistoryEntry(receipt: badReceipt, item: prefsEntry.item))
    }
    var forged = prefsEntry.item
    forged = RemovalOutcome(
        originalPath: root.appendingPathComponent("Documents/secret").path, trashPath: forged.trashPath, error: nil,
        kind: .appData, trashStamp: forged.trashStamp)
    try rejects("Restore cannot write outside approved locations") {
        _ = try restore.validate(HistoryEntry(receipt: receipt, item: forged))
    }
    let outside = root.appendingPathComponent("Not Trash")
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    let stolen = outside.appendingPathComponent("settings.plist")
    try fm.moveItem(at: URL(fileURLWithPath: prefsEntry.item.trashPath!), to: stolen)
    let outsideItem = RemovalOutcome(
        originalPath: preferences.path, trashPath: stolen.path, error: nil, kind: .preferences,
        trashStamp: try FileStamp(stolen))
    try rejects("Restore rejects a source that is not inside Trash") {
        _ = try restore.validate(HistoryEntry(receipt: receipt, item: outsideItem))
    }
    try fm.moveItem(at: stolen, to: URL(fileURLWithPath: prefsEntry.item.trashPath!))
    for entry in entries {
        let destination = try finishAsync { try await restore.restore(entry) }
        try history.markRestored(entry, at: destination)
    }
    try check(
        ApplicationInventory.read(app.url)?.bundleID == app.bundleID && fm.fileExists(atPath: cache.path)
            && fm.fileExists(atPath: preferences.path), "An app and its related files round-trip through Trash")
    try check(
        try history.entries().allSatisfy { $0.item.restoredPath != nil }, "Restored state is persisted for every item")
    try check(
        try Data(contentsOf: damagedRecord) == damagedData,
        "Restoring healthy records does not modify a damaged neighboring record")
    try rejects("Restored files cannot be restored twice") { _ = try restore.validate(try history.entries()[0]) }
    let request = FinderRestore.request(URL(fileURLWithPath: "/tmp/O'Brien \"quoted\".app"), to: app.url)
    try check(
        request.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.atIndex(1)?.stringValue
            == "/tmp/O'Brien \"quoted\".app", "Finder restore paths use typed arguments, not script interpolation")
    var scriptError: NSDictionary?
    try check(
        NSAppleScript(source: FinderRestore.source)?.compileAndReturnError(&scriptError) == true,
        "Finder restore script compiles against the native scripting dictionary")

    // Leftovers are opt-in, limited to observed apps, and checked again at execution.
    try fm.moveItem(at: app.url, to: trash.appendingPathComponent("Notes.app"))
    try file(library.appendingPathComponent("Group Containers/group.org.example/shared.db"))
    try file(library.appendingPathComponent("Caches/org.example.unobserved/data"))
    try file(library.appendingPathComponent("Caches/com.apple.protected/data"))
    let leftovers = LeftoverScanner(scanner: scanner, known: [app.bundleID, "com.apple.protected"])
    let found = try leftovers.scan()
    try check(
        found.groups.count == 1 && found.groups[0].bundleID == app.bundleID && found.groups[0].files.count == 2,
        "Leftover search finds exact files for previously observed, now absent apps")
    try check(
        !found.groups.flatMap(\.files).contains {
            $0.id.contains("Group Containers") || $0.id.contains("unobserved") || $0.id.contains("com.apple.")
        }, "Shared, system and unobserved identifiers are excluded")
    var protectedLeftovers = leftovers
    protectedLeftovers.scanner.deletionProtected = [app.bundleID]
    try check(try protectedLeftovers.scan().groups.isEmpty, "Deletion protection also excludes leftover cleanup")
    let relocated = try makeFixtureApplication(
        root.appendingPathComponent("Elsewhere"), name: "Notes", bundleID: app.bundleID)
    var registered = leftovers
    registered.scanner.registeredApplications = { _ in [relocated.url] }
    try check(try registered.scan().groups.isEmpty, "Apps registered outside Applications protect their data")
    let reinstalled = try makeFixtureApplication(applications, name: "Reinstalled", bundleID: app.bundleID)
    try check(try leftovers.scan().groups.isEmpty, "Reinstalled apps are excluded from leftover scans")
    let blocked = try finishAsync {
        try await leftovers.remove(
            found.groups[0], selected: Set(found.groups[0].files.map(\.id)), history: history, recycle: move)
    }
    try check(
        blocked.hasFailures && blocked.items.allSatisfy { $0.trashPath == nil } && fm.fileExists(atPath: cache.path),
        "Reinstallation between scan and confirmation blocks removal")
    try fm.removeItem(at: reinstalled.url)
    let changedGroup = try leftovers.scan().groups[0]
    try Data("changed preferences".utf8).write(to: preferences)
    let stale = try finishAsync {
        try await leftovers.remove(changedGroup, selected: [preferences.path], history: history, recycle: move)
    }
    try check(stale.hasFailures && fm.fileExists(atPath: preferences.path), "Changed leftovers require a fresh review")
    let freshGroup = try leftovers.scan().groups[0]
    let cancelled = try finishAsync {
        try await leftovers.remove(
            freshGroup, selected: Set(freshGroup.files.map(\.id)), history: history,
            recycle: { _ in throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) })
    }
    try check(
        cancelled.items.count == 1 && cancelled.items[0].failure?.recovery == .cancelled
            && fm.fileExists(atPath: cache.path), "Cancellation stops the remaining cleanup operation")
    let removed = try finishAsync {
        try await leftovers.remove(
            freshGroup, selected: Set(freshGroup.files.map(\.id)), history: history, recycle: move)
    }
    try check(
        !removed.hasFailures && removed.items.count == 2 && !fm.fileExists(atPath: cache.path),
        "Reviewed leftover files move to Trash with restoration metadata")
    let leftoverEntries = try history.entries().filter { $0.receipt.id == removed.id }
    for entry in leftoverEntries { _ = try finishAsync { try await restore.restore(entry) } }
    try check(
        fm.fileExists(atPath: cache.path) && fm.fileExists(atPath: preferences.path),
        "Leftover cleanup can be undone through the same restore engine")
    let failingHistory = RemovalHistory(root: root.appendingPathComponent("Leftover Journal Failure"))
    let failureGroup = try leftovers.scan().groups[0]
    var leftoverMoves = 0
    var leftoverInterruption: RemovalHistoryWriteError?
    do {
        _ = try finishAsync {
            try await leftovers.remove(
                failureGroup, selected: Set(failureGroup.files.map(\.id)), history: failingHistory,
                recycle: { url in
                    let destination = trash.appendingPathComponent(url.lastPathComponent)
                    try fm.moveItem(at: url, to: destination)
                    leftoverMoves += 1
                    try fm.moveItem(
                        at: failingHistory.root, to: root.appendingPathComponent("Original Leftover Journal"))
                    try file(failingHistory.root)
                    return destination
                })
        }
    } catch { leftoverInterruption = error as? RemovalHistoryWriteError }
    try check(
        leftoverMoves == 1 && leftoverInterruption?.receipt.items.filter { $0.trashPath != nil }.count == 1,
        "Leftover cleanup also preserves completed results when its journal becomes unwritable")
    try check(
        leftoverInterruption?.receipt.items.count == 2 && leftoverInterruption?.receipt.hasFailures == true,
        "Leftover cleanup stops before the next file and reports the untouched remainder")
    print("Cleanup and synchronization tests passed: \(checks)")
}
