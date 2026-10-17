import AppKit
import Foundation

// Exercise the real model against disposable data, with no live apply or Dock signals.
func runModelTests() throws {
    let fm = FileManager.default
    let root: URL
    if let i = CommandLine.arguments.firstIndex(of: "--test-directory"), CommandLine.arguments.count > i + 1 {
        root = URL(fileURLWithPath: CommandLine.arguments[i + 1]).appendingPathComponent(UUID().uuidString)
    } else {
        root = fm.temporaryDirectory.appendingPathComponent("LaunchpadStudioModelTests-" + UUID().uuidString)
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? fm.removeItem(at: root)
        L10n.testCode = nil
    }
    L10n.testCode = "en"
    var passed = 0
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw StudioError(message) }
        passed += 1
        print("PASS \(passed): \(message)")
    }
    func mustFail(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch {
            try check(true, message)
            return
        }
        throw StudioError("Expected rejection: " + message)
    }
    let userRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
        "Launchpad Studio")
    let userDraft = try? Data(contentsOf: userRoot.appendingPathComponent("draft.json"))
    let userPrefs = try? Data(contentsOf: userRoot.appendingPathComponent("preferences.json"))
    let live = try TestFixture.source()
    let liveFingerprint = try LaunchpadStore.snapshot(live.path).fingerprint
    let fixture = root.appendingPathComponent("fixture.sqlite")
    try Database(live.path).snapshot(to: fixture)
    let baseline = try LaunchpadStore.snapshot(fixture.path)
    func model(
        _ name: String,
        operation: @escaping StudioModel.ApplyOperation = { _, _, _, _, _ in
            throw StudioError("Unexpected apply in a model test")
        }
    ) throws -> StudioModel {
        let result = StudioModel(
            dataRoot: root.appendingPathComponent(name), locateSource: { fixture }, applyOperation: operation)
        guard result.error == nil else { throw StudioError(result.error!) }
        return result
    }
    let first = try model("restart")
    guard let folder = first.folders.first, first.apps.count >= 5 else {
        throw StudioError("The fixture needs apps and a folder")
    }
    first.rename(folder.id, to: "My edits / 내 편집 / 編集 / 编辑")
    let edited = first.layout
    let control = try model("restart")
    try check(control.layout == edited, "Renames survive model restart")
    control.search = "no-matching-folder"
    control.createFolder()
    try check(
        control.search.isEmpty && control.previewTiles.contains { $0.id == control.selectedTile },
        "A newly created folder stays visible even when a search was active")
    let emptyID = control.selectedTile!
    let withEmpty = control.layout
    let reopened = try model("restart")
    try check(
        reopened.layout == withEmpty, "Restart preserves the entire draft, including empty folders and custom names")
    let diskDraft = try JSONDecoder().decode(
        Draft.self, from: Data(contentsOf: reopened.dataRoot.appendingPathComponent("draft.json")))
    try check(diskDraft.layout == withEmpty, "Reload does not overwrite the draft with a new proposal")
    try check(
        diskDraft.identities?.count == baseline.apps.count,
        "Saved drafts include stable app identities for future installs")
    let exported = root.appendingPathComponent("export.json")
    try JSONEncoder().encode(diskDraft).write(to: exported)
    try check(
        try reopened.readDraft(from: exported, baseline: baseline, apps: reopened.apps) == withEmpty,
        "Exported drafts with empty folders pass the shared import reader")
    try mustFail("Empty folders still block live application") { try withEmpty.validated(for: reopened.apps) }
    var invalid = withEmpty
    invalid.pages[0].tiles[0].appIDs.removeFirst()
    invalid.pages[0].tiles[0].repaginate()
    try mustFail("Draft validation still rejects missing apps") {
        try invalid.validated(for: reopened.apps, purpose: .draft)
    }
    invalid = withEmpty
    invalid.pages[0].tiles[0].appIDs.append(withEmpty.appIDs[0])
    invalid.pages[0].tiles[0].repaginate()
    try mustFail("Draft validation still rejects duplicate apps") {
        try invalid.validated(for: reopened.apps, purpose: .draft)
    }
    invalid = withEmpty
    invalid.pages[0].tiles.append(Tile(name: "Invalid loose app", appIDs: [], isFolder: false))
    try mustFail("Draft validation does not allow empty loose app items") {
        try invalid.validated(for: reopened.apps, purpose: .draft)
    }
    invalid = withEmpty
    invalid.pages[0].tiles[invalid.pages[0].tiles.count - 1].name = "  "
    try mustFail("Draft validation still rejects blank folder names") {
        try invalid.validated(for: reopened.apps, purpose: .draft)
    }

    let ids = reopened.apps.map(\.id)
    let movement = try model("movement-focus")
    let moveSource = Tile(name: "Source only search", appIDs: Array(ids.prefix(2)))
    let moveTarget = Tile(name: "Destination", appIDs: Array(ids.dropFirst(2)))
    movement.edit { $0 = Layout(pages: [LayoutPage(tiles: [moveSource]), LayoutPage(tiles: [moveTarget])]) }
    movement.selectedTile = moveSource.id
    movement.selectedApp = ids[0]
    movement.search = moveSource.name
    movement.moveApps([ids[0]], to: moveTarget.id)
    try check(
        movement.selectedTile == moveTarget.id && movement.inspectedApp?.id == ids[0] && movement.pageIndex == 1,
        "Moving an app follows it to the destination folder and page")
    try check(
        movement.previewTiles.contains { $0.id == moveTarget.id },
        "A folder-name search cannot hide the app after moving it")
    movement.moveApps([ids[0]], to: "__root__")
    try check(
        movement.tile?.isFolder == false && movement.inspectedApp?.id == ids[0],
        "Moving out of a folder keeps the app selected")
    let source = Tile(name: "Source", appIDs: [ids[0]])
    let target = Tile(name: "Target", appIDs: [ids[1]])
    var other = Tile(name: "Keep pagination", appIDs: Array(ids.dropFirst(2)))
    other.pageSizes = [1] + stride(from: 1, to: other.appIDs.count, by: 35).map { min(35, other.appIDs.count - $0) }
    let empty = reopened.folders.first { $0.id == emptyID }!
    reopened.edit { $0 = Layout(pages: [LayoutPage(tiles: [source, target, other]), LayoutPage(tiles: [empty])]) }
    let beforeMove = reopened.layout
    reopened.moveApps([ids[0], ids[0]], to: target.id)
    let afterMove = reopened.layout
    try check(
        afterMove.tiles.contains { $0.id == emptyID } && afterMove.pages.count == 2,
        "Moving apps preserves unrelated empty folders and their pages")
    try check(!afterMove.tiles.contains { $0.id == source.id }, "A source folder emptied by the move is removed")
    try check(
        afterMove.tiles.first { $0.id == target.id }?.appIDs == [ids[1], ids[0]],
        "Repeated drag IDs cannot duplicate an app")
    try check(
        afterMove.tiles.first { $0.id == other.id } == other, "Moving apps preserves pagination in untouched folders")
    try afterMove.validated(for: reopened.apps, purpose: .draft)
    reopened.undo()
    try check(reopened.layout == beforeMove, "Undo restores the exact structure before moving apps")
    reopened.redo()
    try check(reopened.layout == afterMove, "Redo restores the move with the empty folder intact")
    try check(try model("restart").layout == afterMove, "Moved draft with an empty folder survives another restart")
    reopened.moveApps([ids[0]], to: "__root__")
    try check(
        reopened.layout.tiles.contains { $0.id == emptyID }
            && reopened.layout.tiles.contains { !$0.isFolder && $0.appIDs == [ids[0]] },
        "Moving to a root page also preserves unrelated empty folders")
    reopened.moveApps([ids[0]], to: emptyID)
    try check(
        reopened.layout.tiles.first { $0.id == emptyID }?.appIDs == [ids[0]], "An empty folder can still receive apps")
    for (name, data) in [
        ("stale", try JSONEncoder().encode(Draft(fingerprint: "outdated", layout: withEmpty))),
        ("malformed", Data("{unfinished draft".utf8)),
    ] {
        let rejectedRoot = root.appendingPathComponent(name)
        try fm.createDirectory(at: rejectedRoot, withIntermediateDirectories: true)
        try data.write(to: rejectedRoot.appendingPathComponent("draft.json"))
        let rejected = StudioModel(dataRoot: rejectedRoot, locateSource: { fixture })
        let recoveredFiles = try fm.contentsOfDirectory(
            at: rejectedRoot.appendingPathComponent("Recovered Drafts"), includingPropertiesForKeys: nil)
        try check(
            recoveredFiles.count == 1 && (try Data(contentsOf: recoveredFiles[0])) == data,
            "\(name): rejected draft is preserved byte-for-byte before replacement")
        try check(
            rejected.error != nil && rejected.baseline != nil,
            "\(name): recovery is reported and the new preview remains usable")
    }
    let blockedRoot = root.appendingPathComponent("recovery-failure")
    try fm.createDirectory(at: blockedRoot, withIntermediateDirectories: true)
    let damaged = Data("keep this draft".utf8)
    try damaged.write(to: blockedRoot.appendingPathComponent("draft.json"))
    try Data().write(to: blockedRoot.appendingPathComponent("Recovered Drafts"))
    let blocked = StudioModel(dataRoot: blockedRoot, locateSource: { fixture })
    blocked.createFolder()
    try check(
        blocked.error != nil && blocked.baseline == nil
            && (try Data(contentsOf: blockedRoot.appendingPathComponent("draft.json"))) == damaged,
        "A failed recovery copy cannot overwrite the original draft")

    // Installing Launchpad Studio itself is a normal catalog change, not a corrupt draft.
    let installed = baseline.apps.first { $0.bundleID == "local.launchpadstudio.app" } ?? baseline.apps.last!
    let beforeInstallApps = baseline.apps.filter { $0.id != installed.id }
    var customFolder = Tile(name: "Keep my edits / 내 편집", appIDs: beforeInstallApps.map(\.id))
    customFolder.repaginate()
    let waitingFolder = Tile(name: "Keep empty folder", appIDs: [])
    let beforeInstallLayout = Layout(pages: [LayoutPage(tiles: [customFolder, waitingFolder])])
    let beforeInstall = Draft(
        fingerprint: "before-install", layout: beforeInstallLayout,
        identities: beforeInstallApps.map(DraftAppIdentity.init))
    let installRoot = root.appendingPathComponent("install-restart")
    try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
    try JSONEncoder().encode(beforeInstall).write(to: installRoot.appendingPathComponent("draft.json"))
    let afterInstall = try model("install-restart")
    try check(
        Array(afterInstall.layout.tiles.prefix(2)) == [customFolder, waitingFolder],
        "Installing a new app preserves custom names, ordering, pagination, and empty folders")
    try check(
        afterInstall.layout.tiles.last?.appIDs == [installed.id] && afterInstall.layout.tiles.last?.isFolder == false,
        "The newly installed app is appended once without reclassifying existing edits")
    try check(
        !fm.fileExists(atPath: installRoot.appendingPathComponent("Recovered Drafts").path),
        "Normal app installation does not trigger a recovery warning")
    let afterInstallAgain = try model("install-restart")
    try check(
        afterInstallAgain.layout == afterInstall.layout && afterInstallAgain.error == nil,
        "The reconciled draft survives another startup without warnings or duplicate apps")
    let exportedBeforeInstall = root.appendingPathComponent("before-install-export.json")
    try JSONEncoder().encode(beforeInstall).write(to: exportedBeforeInstall)
    try check(
        try afterInstall.readDraft(from: exportedBeforeInstall, baseline: baseline, apps: baseline.apps).semantic
            == afterInstall.layout.semantic, "Import also preserves edits across app installation")

    let removedID = beforeInstallApps[0].id
    let afterRemoval = try beforeInstall.restored(for: baseline, apps: baseline.apps.filter { $0.id != removedID })
    try check(
        !afterRemoval.appIDs.contains(removedID) && afterRemoval.tiles.first?.name == customFolder.name
            && afterRemoval.tiles.contains { $0.id == waitingFolder.id },
        "Uninstalling an app removes only that app from the draft")
    var remappedApps = baseline.apps
    let changedIndex = remappedApps.firstIndex { $0.id == removedID }!
    remappedApps[changedIndex].id = 9_999_999
    let afterIDChange = try beforeInstall.restored(for: baseline, apps: remappedApps)
    try check(
        afterIDChange.tiles[0].appIDs[0] == 9_999_999 && !afterIDChange.appIDs.contains(removedID),
        "Stable identity preserves placement if an app row ID changes")
    var reusedApps = baseline.apps
    reusedApps[changedIndex].uuid = UUID().uuidString
    reusedApps[changedIndex].bundleID = "test.reused.row"
    reusedApps[changedIndex].name = "New unrelated app"
    let afterReuse = try beforeInstall.restored(for: baseline, apps: reusedApps)
    try check(
        !afterReuse.tiles[0].appIDs.contains(removedID)
            && afterReuse.tiles.contains { !$0.isFolder && $0.appIDs == [removedID] },
        "A reused row ID cannot inherit another app's saved folder")
    var metadataOnly = Draft(snapshot: baseline, layout: baseline.layout)
    metadataOnly.fingerprint = "older-metadata"
    try check(
        try metadataOnly.restored(for: baseline, apps: baseline.apps).semantic == baseline.layout.semantic,
        "Metadata-only changes do not invalidate the saved layout")
    var invalidIdentities = beforeInstall
    invalidIdentities.identities!.append(invalidIdentities.identities![0])
    try mustFail("Reject ambiguous saved identities") {
        _ = try invalidIdentities.restored(for: baseline, apps: baseline.apps)
    }
    let foreignApps = baseline.apps.map { app -> AppRecord in
        var result = app
        result.uuid = UUID().uuidString
        return result
    }
    try mustFail("Unrelated app identities cannot be guessed from matching row IDs") {
        _ = try beforeInstall.restored(for: baseline, apps: foreignApps)
    }
    if beforeInstallApps.count >= 35 {
        var fullTiles = beforeInstallApps.prefix(34).map {
            Tile(id: "app-\($0.id)", name: $0.name, appIDs: [$0.id], isFolder: false)
        }
        var rest = Tile(name: "Remaining", appIDs: beforeInstallApps.dropFirst(34).map(\.id))
        rest.repaginate()
        fullTiles.append(rest)
        let fullDraft = Draft(
            fingerprint: "before-install", layout: Layout(pages: [LayoutPage(tiles: fullTiles)]),
            identities: beforeInstall.identities)
        let overflow = try fullDraft.restored(for: baseline, apps: baseline.apps)
        try check(
            overflow.pages.count == 2 && overflow.pages[0].tiles == fullTiles
                && overflow.pages[1].tiles[0].appIDs == [installed.id],
            "Installing an app on a full page adds a new page without disturbing the existing page")
    }
    let legacyRoot = root.appendingPathComponent("legacy-upgrade")
    try fm.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
    try JSONEncoder().encode(Draft(fingerprint: baseline.fingerprint, layout: baseline.layout)).write(
        to: legacyRoot.appendingPathComponent("draft.json"))
    let upgraded = try model("legacy-upgrade")
    let upgradedDisk = try JSONDecoder().decode(
        Draft.self, from: Data(contentsOf: legacyRoot.appendingPathComponent("draft.json")))
    try check(
        upgraded.layout == baseline.layout && upgradedDisk.identities?.count == baseline.apps.count,
        "Compatible legacy drafts gain identities without changing their layout")

    let application = NSApplication.shared
    let delegate = AppDelegate()
    // No window is ordered on screen and NSApplication.run/terminate are never called.
    let testWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    for fail in [false, true] {
        let probe = ModelApplyProbe()
        let applying = try model(fail ? "apply-failure" : "apply-success") {
            layout, snapshot, source, backups, reason in
            probe.started()
            guard probe.release.wait(timeout: .now() + 10) == .success else {
                throw StudioError("Timed out waiting for the model test")
            }
            if fail { throw StudioError("Simulated apply failure") }
            guard source == fixture, source != live else {
                throw StudioError("Refusing a live write in the model tests")
            }
            let backup = try backups.create(source: source, reason: reason)
            let db = try Database(source.path, writable: true)
            try db.execute("BEGIN IMMEDIATE")
            do {
                try LaunchpadStore.write(layout, to: db, baseline: snapshot)
                try db.execute("COMMIT")
            } catch {
                try? db.execute("ROLLBACK")
                throw error
            }
            return backup
        }
        let folderID = applying.folders[0].id
        applying.rename(folderID, to: "Apply draft")
        applying.rename(folderID, to: "Later edit")
        applying.undo()
        let targetLayout = applying.layout
        let oldUndo = applying.undoStack
        let oldRedo = applying.redoStack
        let savedDraft = try Data(contentsOf: applying.dataRoot.appendingPathComponent("draft.json"))
        delegate.model = applying
        applying.apply()
        defer { probe.release.signal() }
        guard probe.entered.wait(timeout: .now() + 5) == .success else {
            throw StudioError("Apply operation did not start")
        }
        try check(
            applying.busy && delegate.applicationShouldTerminate(application) == .terminateCancel
                && !delegate.windowShouldClose(testWindow),
            "\(fail ? "Failure" : "Success") path: Quit and close are refused throughout apply")
        applying.undo()
        applying.redo()
        applying.rename(folderID, to: "Blocked edit")
        applying.apply()
        try check(
            applying.layout == targetLayout && applying.undoStack == oldUndo && applying.redoStack == oldRedo
                && (try Data(contentsOf: applying.dataRoot.appendingPathComponent("draft.json"))) == savedDraft,
            "Busy apply blocks edits, undo, redo, and draft writes")
        probe.release.signal()
        let deadline = Date().addingTimeInterval(10)
        while applying.busy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try check(
            !applying.busy && probe.count == 1,
            "Apply completes once; repeated apply requests cannot start another operation")
        try check(
            delegate.applicationShouldTerminate(application) == .terminateNow && delegate.windowShouldClose(testWindow),
            "Quit and close become available after \(fail ? "failure" : "success")")
        if fail {
            try check(
                applying.error == "Simulated apply failure" && applying.layout == targetLayout
                    && applying.undoStack == oldUndo, "Failed apply retains the editable draft and undo history")
        } else {
            try check(
                applying.error == nil && applying.layout.semantic == targetLayout.semantic && applying.undoStack.isEmpty
                    && applying.redoStack.isEmpty,
                "Successful apply reloads the committed fixture before releasing the busy state")
        }
    }
    try check(
        (try? Data(contentsOf: userRoot.appendingPathComponent("draft.json"))) == userDraft
            && (try? Data(contentsOf: userRoot.appendingPathComponent("preferences.json"))) == userPrefs,
        "Real user draft and preferences are byte-for-byte unchanged")
    try check(try LaunchpadStore.snapshot(live.path).fingerprint == liveFingerprint, "Source database is unchanged")
    print(
        "SUCCESS: \(passed) model/lifecycle checks passed. All writes used temporary data. Live Dock restart was not exercised."
    )
}

private final class ModelApplyProbe {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
    func started() {
        lock.lock()
        calls += 1
        lock.unlock()
        entered.signal()
    }
}
