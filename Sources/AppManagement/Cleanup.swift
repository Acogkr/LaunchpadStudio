import AppKit

// History is local, version tolerant, and stores the identity at the actual Trash URL.
// A path alone is never sufficient to restore an older deletion.
struct RemovalHistory {
    let root: URL
    func save(_ receipt: RemovalReceipt) throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(receipt).write(
            to: root.appendingPathComponent(receipt.id.uuidString + ".json"), options: .atomic)
    }
    func read() throws -> (receipts: [RemovalReceipt], unreadableCount: Int) {
        guard FileManager.default.fileExists(atPath: root.path) else { return ([], 0) }
        var receipts: [RemovalReceipt] = []
        var unreadableCount = 0
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" && AppPaths.isDirect($0) })
        {
            do {
                let receipt = try JSONDecoder().decode(RemovalReceipt.self, from: Data(contentsOf: file))
                guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) == receipt.id else {
                    throw StudioError(L("The deletion record changed. Refresh and try again."))
                }
                receipts.append(receipt)
            } catch { unreadableCount += 1 }  // Preserve unreadable files; one bad record cannot hide all the others.
        }
        return (receipts.sorted { $0.date > $1.date }, unreadableCount)
    }
    func load() throws -> [RemovalReceipt] { try read().receipts }
    func entries(from receipts: [RemovalReceipt]? = nil) throws -> [HistoryEntry] {
        var seen = Set<String>()
        return try (receipts ?? load()).flatMap { receipt in
            receipt.items.compactMap { item in
                guard let trash = item.trashPath else { return nil }
                let key = "\(trash)|\(item.trashStamp?.device ?? 0)|\(item.trashStamp?.inode ?? 0)"
                guard seen.insert(key).inserted else { return nil }
                return HistoryEntry(receipt: receipt, item: item)
            }
        }
    }
    func markRestored(_ entry: HistoryEntry, at destination: URL) throws {
        let file = root.appendingPathComponent(entry.receipt.id.uuidString + ".json")
        guard AppPaths.isDirect(file) else {
            throw StudioError(L("The deletion record changed. Refresh and try again."))
        }
        var current = try JSONDecoder().decode(RemovalReceipt.self, from: Data(contentsOf: file))
        guard current.id == entry.receipt.id,
            let index = current.items.firstIndex(where: {
                $0.originalPath == entry.item.originalPath && $0.trashPath == entry.item.trashPath
                    && $0.trashStamp == entry.item.trashStamp
            })
        else {
            throw StudioError(L("The deletion record changed. Refresh and try again."))
        }
        current.items[index].restoredPath = destination.path
        try save(current)
    }
}
struct HistoryEntry: Identifiable {
    let receipt: RemovalReceipt
    let item: RemovalOutcome
    var id: String { receipt.id.uuidString + "|" + item.originalPath }
}

struct TrashRestore {
    var scanner: RemovalScanner
    var trashRoots: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")]
    // External disks use a per-user .Trashes directory; never accept another user's Trash.
    func isTrashLocation(_ url: URL) -> Bool {
        if trashRoots.contains(where: { url.deletingLastPathComponent().standardizedFileURL == $0.standardizedFileURL })
        {
            return true
        }
        let parent = url.deletingLastPathComponent()
        guard parent.lastPathComponent == String(getuid()),
            parent.deletingLastPathComponent().lastPathComponent == ".Trashes",
            let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume
        else { return false }
        return parent.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
            == volume.standardizedFileURL
    }
    func validateDestination(_ entry: HistoryEntry) throws -> URL {
        let item = entry.item
        let destination = URL(fileURLWithPath: entry.item.originalPath)
        guard item.originalPath.hasPrefix("/"), destination.standardizedFileURL.path == item.originalPath,
            AppPaths.isDirect(destination), let kind = item.kind, let identifier = entry.receipt.bundleID,
            AppPaths.identifierIsSafe(identifier), identifier != scanner.protectedBundleID
        else {
            throw StudioError(L("This older record cannot be verified. Open Trash to restore it manually."))
        }
        if kind == .application {
            let app = InstalledApplication(
                path: destination.path, bundleID: identifier, name: entry.receipt.appName, version: "", revision: "")
            var locations = scanner
            locations.deletionProtected = []  // Protection prevents removal, not recovery.
            try locations.validateLocation(app)
            guard destination.pathExtension.lowercased() == "app" else {
                throw StudioError(L("Could not verify this file."))
            }
        } else {
            guard
                scanner.libraryRoots.contains(where: { library in
                    let parent = destination.deletingLastPathComponent()
                    let name = destination.lastPathComponent
                    let folders = [
                        "Caches", "Preferences", "Saved Application State", "Logs", "HTTPStorages", "Cookies",
                        "Application Scripts", "WebKit", "Application Support", "Containers",
                    ]
                    for folder in folders where parent == library.appendingPathComponent(folder) {
                        if name == identifier || name == identifier + ".plist" || name == identifier + ".savedState"
                            || name == identifier + ".binarycookies"
                        {
                            return true
                        }
                        if ["Caches", "Logs", "Application Support"].contains(folder), name.count >= 3,
                            [entry.receipt.appName, entry.receipt.appFileName].compactMap({ $0 }).contains(name),
                            !name.contains("/"), name != ".."
                        {
                            return true
                        }
                    }
                    if parent == library.appendingPathComponent("Preferences/ByHost"), name.hasPrefix(identifier + "."),
                        name.hasSuffix(".plist")
                    {
                        return UUID(uuidString: String(name.dropFirst(identifier.count + 1).dropLast(6))) != nil
                    }
                    return false
                })
            else { throw StudioError(L("Could not verify this file.")) }
        }
        return destination
    }
    func validate(_ entry: HistoryEntry) throws -> (URL, URL) {
        if entry.item.restoredPath != nil { throw StudioError(L("Restored")) }
        let destination = try validateDestination(entry)
        guard let path = entry.item.trashPath, let expected = entry.item.trashStamp else {
            throw StudioError(L("This older record cannot be verified. Open Trash to restore it manually."))
        }
        let source = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: source.path) else { throw StudioError(L("No longer in Trash")) }
        guard isTrashLocation(source), AppPaths.isDirect(source), try FileStamp(source) == expected else {
            throw StudioError(L("The file in Trash changed. Restore it manually in Finder."))
        }
        if entry.item.kind == .application {
            guard ApplicationInventory.read(source)?.bundleID == entry.receipt.bundleID else {
                throw StudioError(L("Could not verify this file."))
            }
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw StudioError(L("An item already exists at the original location."))
        }
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: destination.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw StudioError(L("The original folder no longer exists."))
        }
        return (source, destination)
    }
    func restore(
        _ entry: HistoryEntry,
        finderMove: (URL, URL) async throws -> URL = { source, destination in
            try await MainActor.run { try FinderRestore.move(source, to: destination) }
        }
    ) async throws -> URL {
        let (source, destination) = try validate(entry)
        do { try FileManager.default.moveItem(at: source, to: destination) } catch {
            guard RemovalFailure(error, url: destination, kind: entry.item.kind ?? .appData).permitsAutomaticFinderRetry
            else { throw error }
            _ = try validate(entry)
            return try await finderMove(source, destination)
        }
        return destination
    }
}

struct LeftoverGroup: Identifiable {
    let bundleID: String
    let files: [RemovalCandidate]
    var name: String? = nil
    var id: String { bundleID }
}
struct LeftoverResult {
    let groups: [LeftoverGroup]
    let notes: [String]
}
struct LeftoverScanner {
    var scanner: RemovalScanner
    // Only identities observed as real apps are considered. A reverse-DNS filename
    // alone may belong to a helper, extension or a shared service.
    var known: Set<String>
    var names: [String: String] = [:]
    func isInstalled(_ identifier: String, installed: Set<String>? = nil) throws -> Bool {
        let installed = try installed ?? Set(ApplicationInventory.scan(roots: scanner.applicationRoots).map(\.bundleID))
        if installed.contains(identifier) { return true }
        if try scanner.hasInstalledApplication(identifier, installed: []) { return true }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == identifier }
    }
    func files(for identifier: String, installed: Set<String>? = nil) throws -> RemovalPlan? {
        guard known.contains(identifier), AppPaths.identifierIsSafe(identifier),
            !identifier.lowercased().hasPrefix("com.apple."),
            identifier != scanner.protectedBundleID, !scanner.deletionProtected.contains(identifier),
            !scanner.applicationRoots.isEmpty, try !isInstalled(identifier, installed: installed)
        else { return nil }
        let absent = InstalledApplication(
            path: scanner.applicationRoots[0].appendingPathComponent(identifier + ".app").path,
            bundleID: identifier, name: identifier, version: "", revision: "")
        return try scanner.scan(absent, appAlreadyRemoved: true, includeNameMatches: false)
    }
    func scan() throws -> LeftoverResult {
        var groups: [LeftoverGroup] = []
        var notes = Set<String>()
        let installed = Set(try ApplicationInventory.scan(roots: scanner.applicationRoots).map(\.bundleID))
        for identifier in known.sorted() {
            guard let plan = try files(for: identifier, installed: installed) else { continue }
            notes.formUnion(plan.notes)
            if !plan.candidates.isEmpty {
                groups.append(LeftoverGroup(bundleID: identifier, files: plan.candidates, name: names[identifier]))
            }
        }
        return LeftoverResult(groups: groups, notes: notes.sorted())
    }
    func remove(
        _ group: LeftoverGroup, selected: Set<String>, history: RemovalHistory,
        recycle: ApplicationRemoval.Recycle = ApplicationRemoval.recycle,
        finderRecycle: ApplicationRemoval.Recycle = { url in try await MainActor.run { try FinderTrash.recycle(url) } }
    ) async throws -> RemovalReceipt {
        guard !selected.isEmpty, selected.isSubset(of: Set(group.files.map(\.id))) else {
            throw StudioError(L("The removal selection is invalid."))
        }
        var receipt = RemovalReceipt(
            id: UUID(), date: Date(), appName: group.name ?? group.bundleID, items: [], bundleID: group.bundleID)
        // Save an empty journal before touching any files so an unwritable history aborts safely.
        func saveProgress() throws {
            do { try history.save(receipt) } catch {
                throw RemovalHistoryWriteError(
                    receipt: receipt, remaining: group.files.filter { selected.contains($0.id) }, underlying: error)
            }
        }
        try saveProgress()
        for file in group.files where selected.contains(file.id) {
            do {
                guard let fresh = try files(for: group.bundleID),
                    let match = fresh.candidates.first(where: { $0.id == file.id }), match.stamp == file.stamp
                else {
                    throw StudioError(L("The app or related files changed. Scan again."))
                }
                try scanner.revalidate(file)
                let destination: URL
                do { destination = try await recycle(file.url) } catch {
                    guard RemovalFailure(error, url: file.url, kind: file.kind).permitsAutomaticFinderRetry else {
                        throw error
                    }
                    guard try !isInstalled(group.bundleID) else {
                        throw StudioError(L("The app or related files changed. Scan again."))
                    }
                    try scanner.revalidate(file)
                    destination = try await finderRecycle(file.url)
                }
                receipt.items.append(
                    RemovalOutcome(
                        originalPath: file.id, trashPath: destination.path, error: nil, kind: file.kind,
                        trashStamp: try? FileStamp(destination)))
            } catch {
                let failure = RemovalFailure(error, url: file.url, kind: file.kind)
                receipt.items.append(
                    RemovalOutcome(
                        originalPath: file.id, trashPath: nil, error: error.localizedDescription, failure: failure))
                try saveProgress()
                // Do not keep asking for authorization after a cancellation or denial.
                break
            }
            try saveProgress()
        }
        return receipt
    }
}
