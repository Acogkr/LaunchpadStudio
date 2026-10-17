import Foundation

func runSelfTests() throws {
    let fm = FileManager.default
    let root: URL
    if let i = CommandLine.arguments.firstIndex(of: "--test-directory"), CommandLine.arguments.count > i + 1 {
        root = URL(fileURLWithPath: CommandLine.arguments[i + 1]).appendingPathComponent(UUID().uuidString)
    } else {
        root = fm.temporaryDirectory.appendingPathComponent("LaunchpadStudioTests-" + UUID().uuidString)
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    var passed = 0
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw StudioError(message) }
        passed += 1
        print("PASS \(passed): \(message)")
    }
    func mustFail(_ name: String, _ action: () throws -> Void) throws {
        do { try action() } catch {
            passed += 1
            print("PASS \(passed): \(name)")
            return
        }
        throw StudioError("Expected rejection: " + name)
    }
    let live = try TestFixture.source()
    let originalLive = try LaunchpadStore.snapshot(live.path)
    let fixture = root.appendingPathComponent("fixture.sqlite")
    try Database(live.path).snapshot(to: fixture)
    let baseline = try LaunchpadStore.snapshot(fixture.path)
    try check(
        !baseline.apps.isEmpty,
        "Read source Launchpad apps (\(baseline.apps.count)), excluding \(baseline.hiddenCount) hidden records")
    let manager = try BackupManager(root: root.appendingPathComponent("Backups"))
    let backup = try manager.create(source: fixture, reason: "test snapshot")
    try check(
        try manager.read(backup).fingerprint == baseline.fingerprint, "SQLite backup includes committed WAL state")
    let proposed = Classifier.propose(
        apps: baseline.apps, rules: [], current: baseline.layout, locked: [], preserveFolders: false)
    try proposed.validated(for: baseline.apps)
    try check(
        proposed.appIDs.count == baseline.apps.count && Set(proposed.appIDs) == Set(baseline.apps.map(\.id)),
        "Classification includes every visible app exactly once")
    let db = try Database(fixture.path, writable: true)
    let originalAppData = try db.rows(
        "SELECT item_id,title,bundleid,hex(bookmark) AS bookmark,category_id,moddate FROM apps ORDER BY item_id")
    let originalImages = try LaunchpadStore.digest(
        db.rows("SELECT item_id,hex(image_data) AS big,hex(image_data_mini) AS mini FROM image_cache ORDER BY item_id"))
    try db.execute("BEGIN IMMEDIATE")
    try LaunchpadStore.write(proposed, to: db, baseline: baseline)
    try db.execute("COMMIT")
    let applied = try LaunchpadStore.snapshot(fixture.path)
    try check(
        applied.layout.semantic == proposed.semantic, "Apply classification with exact folder names and app order")
    try check(
        try db.rows(
            "SELECT item_id,title,bundleid,hex(bookmark) AS bookmark,category_id,moddate FROM apps ORDER BY item_id")
            == originalAppData, "All app metadata and bookmarks preserved")
    try check(
        try LaunchpadStore.digest(
            db.rows(
                "SELECT item_id,hex(image_data) AS big,hex(image_data_mini) AS mini FROM image_cache ORDER BY item_id"))
            == originalImages, "Icon cache preserved")
    let touched = Set(baseline.containers + baseline.layout.appIDs)
    let originalHidden = baseline.allRows.filter { !touched.contains(Int64($0["rowid"]!)!) }
    let originalHiddenIDs = Set(originalHidden.compactMap { $0["rowid"] })
    try check(
        applied.allRows.filter { originalHiddenIDs.contains($0["rowid"]!) } == originalHidden,
        "Hidden roots, version records and orphan records unchanged")
    var manual = proposed
    manual.pages[0].tiles[0].name = "나의 개발 도구 '한글' / 開発 / 工具"
    if manual.pages[0].tiles.count > 1, let app = manual.pages[0].tiles[0].appIDs.popLast() {
        manual.pages[0].tiles[1].appIDs.insert(app, at: 0)
        manual.pages[0].tiles[0].repaginate()
        manual.pages[0].tiles[1].repaginate()
    }
    try db.execute("BEGIN IMMEDIATE")
    try LaunchpadStore.write(manual, to: db, baseline: applied)
    try db.execute("COMMIT")
    try check(
        try LaunchpadStore.snapshot(fixture.path).layout.semantic == manual.semantic,
        "Manual moves, ordering and quoted Korean folder names round-trip")
    let beforeRollback = try LaunchpadStore.snapshot(fixture.path)
    try db.execute("BEGIN IMMEDIATE")
    try LaunchpadStore.write(proposed, to: db, baseline: beforeRollback)
    try db.execute("ROLLBACK")
    try check(
        try LaunchpadStore.snapshot(fixture.path).fingerprint == beforeRollback.fingerprint,
        "Transaction rollback restores all layout records after a staged mutation")
    try db.execute("BEGIN IMMEDIATE")
    try LaunchpadStore.write(try manager.read(backup).layout, to: db, baseline: beforeRollback)
    try db.execute("COMMIT")
    let restored = try LaunchpadStore.snapshot(fixture.path)
    try check(
        restored.layout.semantic == baseline.layout.semantic,
        "Restore original pages, folders, folder pagination and app ordering")
    try check(restored.catalog == baseline.catalog, "App identity is unchanged by apply and restore")
    try mustFail("Reject stale preview after external layout change") {
        try db.execute("BEGIN IMMEDIATE")
        defer { try? db.execute("ROLLBACK") }
        try LaunchpadStore.write(proposed, to: db, baseline: baseline)
    }
    var duplicate = proposed
    duplicate.pages[0].tiles[0].appIDs.append(proposed.appIDs[0])
    duplicate.pages[0].tiles[0].repaginate()
    try mustFail("Reject duplicate apps") { try duplicate.validated(for: baseline.apps) }
    var missing = proposed
    missing.pages[0].tiles[0].appIDs.removeLast()
    missing.pages[0].tiles[0].repaginate()
    try mustFail("Reject missing apps") { try missing.validated(for: baseline.apps) }
    var empty = proposed
    empty.pages[0].tiles.append(Tile(name: "empty", appIDs: []))
    try mustFail("Reject empty folders before live write") { try empty.validated(for: baseline.apps) }
    let first = baseline.apps[0]
    let rule = Rule(keyword: first.bundleID, folder: "사용자 지정")
    try check(
        Classifier.classify(first, rules: [rule]).folder == "사용자 지정",
        "User rule takes priority over built-in categories")
    let password = AppRecord(
        id: 999, name: "1Password 7", bundleID: "com.agilebits.onepassword7",
        category: "public.app-category.productivity", uuid: "test")
    try check(
        Classifier.classify(password, rules: []).folder == L("System Tools"),
        "Password apps do not match the Microsoft Word classification")
    let locked = Classifier.propose(
        apps: baseline.apps, rules: [], current: baseline.layout, locked: [first.id], preserveFolders: false)
    try check(
        locked.tiles.first(where: { $0.appIDs.contains(first.id) })?.isFolder
            == baseline.layout.tiles.first(where: { $0.appIDs.contains(first.id) })?.isFolder,
        "Classification lock preserves folder/loose placement")
    let preserve = Classifier.propose(
        apps: baseline.apps, rules: [], current: baseline.layout, locked: [], preserveFolders: true)
    try check(
        baseline.layout.tiles.filter(\.isFolder).allSatisfy { old in
            preserve.tiles.contains { $0.name == old.name && Set(old.appIDs).isSubset(of: Set($0.appIDs)) }
        }, "Preserve existing folders option")
    let oneFolderApps = (1...80).map {
        AppRecord(
            id: Int64($0), name: "Utility \($0)", bundleID: "test.utility.\($0)",
            category: "public.app-category.utilities", uuid: "\($0)")
    }
    let paged = Classifier.propose(
        apps: oneFolderApps, rules: [], current: Layout(pages: []), locked: [], preserveFolders: false)
    try check(paged.tiles[0].pageSizes == [35, 35, 10], "Folder overflow is split into 35-item pages")
    try db.execute("UPDATE dbinfo SET value=14 WHERE key='version'")
    try mustFail("Reject unknown Launchpad schema version") { _ = try LaunchpadStore.snapshot(fixture.path) }
    try db.execute("UPDATE dbinfo SET value=13 WHERE key='version'")
    try db.execute("INSERT INTO downloading_apps(item_id,title) VALUES(999999,'Pending')")
    try mustFail("Reject active app downloads") { _ = try LaunchpadStore.snapshot(fixture.path) }
    try db.execute("DELETE FROM downloading_apps WHERE item_id=999999")
    let damaged = manager.root.appendingPathComponent(backup.id + ".sqlite")
    let h = try FileHandle(forWritingTo: damaged)
    try h.seekToEnd()
    try h.write(contentsOf: Data([0]))
    try h.close()
    try mustFail("Reject modified backup using SHA-256") { _ = try manager.read(backup) }
    try check(
        try LaunchpadStore.snapshot(live.path).fingerprint == originalLive.fingerprint,
        "Source database layout unchanged by the complete test suite")
    print(
        "SUCCESS: \(passed) checks passed. All mutations used disposable database copies. Live Dock restart was not exercised."
    )
}
