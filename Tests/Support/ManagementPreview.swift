import Foundation

// Compiled only into test bundles. Its paths and database are synthetic.
func makeManagementPreview(_ root: URL) throws -> StudioModel {
    guard root.lastPathComponent == "management-preview" else { throw StudioError("Unexpected preview location") }
    let fm = FileManager.default
    let database = root.appendingPathComponent("launchpad.sqlite")
    guard fm.fileExists(atPath: database.path) else { throw StudioError("Generate the preview database first") }
    let applications = root.appendingPathComponent("Applications")
    let library = root.appendingPathComponent("Library")
    let previewCase = Bundle.main.object(forInfoDictionaryKey: "StudioPreviewCase") as? String
    var names = [
        "Pages", "Numbers", "Keynote", "Xcode", "Visual Studio Code", "Figma", "Pixelmator", "Music", "Slack", "Notion",
        "Obsidian", "Linear",
    ]
    if previewCase == "authorization" { names[10] = "Launchpad Studio Test" }
    let db = try Database(database.path, writable: true)
    try db.execute("DELETE FROM items WHERE type=4 AND rowid>=1012 AND rowid<2000")
    var installed: [InstalledApplication] = []
    for (offset, name) in names.enumerated() {
        let id = Int64(1000 + offset)
        let identifier =
            previewCase == "cleanup"
            ? "org.example.launchpad-cleanup-20261015.app\(offset+1)" : "org.example.launchpad-fixture.app\(offset+1)"
        let app = try makeFixtureApplication(applications, name: name, bundleID: identifier)
        installed.append(app)
        let bookmark = try app.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil).map {
            String(format: "%02X", $0)
        }.joined()
        try db.execute(
            "UPDATE apps SET title=?,bundleid=?,bookmark=X'\(bookmark)' WHERE item_id=?",
            [name, identifier, String(id)])
    }
    let target = installed[10]
    for (relative, count) in [
        ("Caches/\(target.bundleID)/cache.bin", 1_000_000), ("Preferences/\(target.bundleID).plist", 2_000),
        ("Application Support/\(target.name)/Notes.md", 20_000), ("Logs/\(target.bundleID)/app.log", 8_000),
    ] {
        let path = library.appendingPathComponent(relative)
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path.path) { try Data(repeating: 65, count: count).write(to: path) }
    }
    let model = StudioModel(
        dataRoot: root.appendingPathComponent("Data"), locateSource: { database },
        applyOperation: { _, _, _, _, _ in throw StudioError("Apply is disabled in the preview") },
        removalScanner: RemovalScanner(applicationRoots: [applications], libraryRoots: [library]))
    model.moveApps([1010, 1011], to: "__root__")
    model.discovery = AppDiscoveryState(
        initialized: true, known: Set(installed.dropLast(2).map(\.bundleID)), pending: [])
    model.receiveApplications(installed)
    model.selectedTab = "preview"
    if previewCase == "authorization" {
        model.removalTarget = target
        model.removalPlan = try model.removalScanner.scan(target)
        model.removalSelection = [target.path]
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: applications.path)
    }
    if previewCase == "access-failure" {
        let plan = try model.removalScanner.scan(target)
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        model.removalTarget = target
        model.removalPlan = plan
        model.removalSelection = Set(plan.candidates.filter(\.selectedByDefault).map(\.id))
        model.removalReceipt = RemovalReceipt(
            id: UUID(), date: Date(), appName: target.name,
            items: [
                RemovalOutcome(
                    originalPath: target.path, trashPath: nil, error: error.localizedDescription,
                    failure: RemovalFailure(error, url: target.url, kind: .application))
            ])
    }
    return model
}
