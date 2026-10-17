import Foundation

// Page IDs vary across databases; the synthetic fixture's row 4 may be hidden on a real Mac.
func makeFixturePage(_ db: Database, id: Int64) throws {
    let catalog = try LaunchpadStore.read(db)
    let lastOrder = catalog.allRows.filter { $0["parent_id"] == String(catalog.root) }
        .compactMap { Int($0["ordering"] ?? "") }.max() ?? 0
    try db.execute("INSERT INTO items(rowid,uuid,flags,type,parent_id,ordering) VALUES (?,?,2,3,?,?)",
                   [String(id), UUID().uuidString, String(catalog.root), String(lastOrder + 1)])
    try db.execute("INSERT INTO groups(item_id,category_id,title) VALUES (?,NULL,NULL)", [String(id)])
}

func makeFixtureApplication(_ parent: URL, name: String, bundleID: String, version: String = "1.0") throws
    -> InstalledApplication
{
    let url = parent.appendingPathComponent(name + ".app")
    let contents = url.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(
        at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": bundleID, "CFBundleExecutable": "Fixture", "CFBundleName": name,
        "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
        to: contents.appendingPathComponent("Info.plist"))
    let executable = contents.appendingPathComponent("MacOS/Fixture")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    guard let app = ApplicationInventory.read(url) else { throw StudioError("Fixture bundle was not recognized") }
    return app
}

private final class AsyncTestResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<T, Error>?
    func put(_ value: Result<T, Error>) {
        lock.lock()
        storage = value
        lock.unlock()
    }
    var value: Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
func finishAsync<T>(_ operation: @escaping () async throws -> T) throws -> T {
    let result = AsyncTestResult<T>()
    let task = Task.detached {
        do { result.put(.success(try await operation())) } catch { result.put(.failure(error)) }
    }
    let deadline = Date().addingTimeInterval(30)
    while result.value == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    guard let value = result.value else {
        task.cancel()
        throw StudioError("Async test timed out")
    }
    return try value.get()
}
