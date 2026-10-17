import AppKit
import Foundation

struct FileStamp: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modified: TimeInterval
    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw StudioError(L("This file is a symbolic link."))
        }
        device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        guard inode != 0 else { throw StudioError(L("Could not verify this file.")) }
    }
}

enum RemovalKind: String, Codable {
    case application, cache, preferences, savedState, logs, appData
    var title: String {
        switch self {
        case .application: return L("Application")
        case .cache: return L("Cache")
        case .preferences: return L("Preferences")
        case .savedState: return L("Saved State")
        case .logs: return L("Logs")
        case .appData: return L("App Data")
        }
    }
}
struct RemovalCandidate: Identifiable {
    let url: URL
    let kind: RemovalKind
    let stamp: FileStamp
    let bytes: Int64?
    let needsReview: Bool
    var id: String { url.path }
    var selectedByDefault: Bool { !needsReview }
    var sizeLabel: String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? L("Size unavailable")
    }
}
struct RemovalPlan: Identifiable {
    let id = UUID()
    let app: InstalledApplication
    let candidates: [RemovalCandidate]
    let notes: [String]
    var accessIssues: [RemovalFailure] = []
}
struct RemovalOutcome: Codable, Identifiable {
    var id: String { originalPath }
    let originalPath: String
    let trashPath: String?
    let error: String?
    var failure: RemovalFailure? = nil
    var kind: RemovalKind? = nil
    var trashStamp: FileStamp? = nil
    var restoredPath: String? = nil
}
struct RemovalReceipt: Codable, Identifiable {
    let id: UUID
    let date: Date
    let appName: String
    var items: [RemovalOutcome]
    var bundleID: String? = nil
    var appFileName: String? = nil
    var hasFailures: Bool { items.contains { $0.trashPath == nil } }
}

// A failed journal write must not discard the locations of files already moved.
struct RemovalHistoryWriteError: LocalizedError {
    let receipt: RemovalReceipt
    let underlying: Error
    var errorDescription: String? { L("The deletion history could not be saved. Remaining files were not moved.") }
    init(receipt: RemovalReceipt, remaining: [RemovalCandidate], underlying: Error) {
        var partial = receipt
        let recorded = Set(partial.items.map(\.originalPath))
        partial.items += remaining.filter { !recorded.contains($0.id) }.map {
            RemovalOutcome(
                originalPath: $0.id, trashPath: nil,
                error: L("The deletion history could not be saved. Remaining files were not moved."), kind: $0.kind)
        }
        self.receipt = partial
        self.underlying = underlying
    }
}

struct RemovalScanner {
    var applicationRoots = AppPaths.applicationRoots.map { $0.resolvingSymlinksInPath() }
    var libraryRoots = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"),
        URL(fileURLWithPath: "/Library"),
    ]
    var protectedBundleID = "local.launchpadstudio.app"
    var deletionProtected: Set<String> = []
    var registeredApplications: (String) -> [URL] = { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }

    func hasInstalledApplication(
        _ identifier: String, excluding excluded: URL? = nil, installed: [InstalledApplication]? = nil
    ) throws -> Bool {
        let inventory = try installed ?? ApplicationInventory.scan(roots: applicationRoots)
        let excludedPath = excluded?.resolvingSymlinksInPath().standardizedFileURL.path
        if inventory.contains(where: { $0.bundleID == identifier && $0.path != excludedPath }) { return true }
        // Launch Services also knows copies in Downloads, mounted disks and custom folders.
        // Ignore stale registrations and real Trash destinations, including after moving the app.
        let restore = TrashRestore(scanner: self)
        return registeredApplications(identifier).contains { url in
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            return resolved.path != excludedPath && FileManager.default.fileExists(atPath: resolved.path)
                && !restore.isTrashLocation(resolved)
        }
    }

    func validateLocation(_ app: InstalledApplication) throws {
        guard !deletionProtected.contains(app.bundleID) else {
            throw StudioError(L("This app is protected from deletion."))
        }
        guard app.bundleID != protectedBundleID, AppPaths.identifierIsSafe(app.bundleID),
            applicationRoots.contains(where: { AppPaths.contains(app.url, in: $0) }), AppPaths.isDirect(app.url),
            !app.url.pathComponents.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") })
        else {
            throw StudioError(L("This app cannot be removed from here."))
        }
    }
    func validateApp(_ app: InstalledApplication) throws {
        try validateLocation(app)
        guard let current = ApplicationInventory.read(app.url), current.bundleID == app.bundleID else {
            throw StudioError(L("This app cannot be removed from here."))
        }
    }
    func scan(_ app: InstalledApplication, appAlreadyRemoved: Bool = false, includeNameMatches: Bool = true) throws
        -> RemovalPlan
    {
        if appAlreadyRemoved {
            try validateLocation(app)
            guard !FileManager.default.fileExists(atPath: app.path) else {
                throw StudioError(L("The app or related files changed. Scan again."))
            }
        } else {
            try validateApp(app)
        }
        let installed = try ApplicationInventory.scan(roots: applicationRoots)
        var notes: [String] = []
        var accessIssues: [RemovalFailure] = []
        var candidates: [RemovalCandidate] = []
        func add(_ rawURL: URL, _ kind: RemovalKind, review: Bool = false) {
            let url = rawURL.standardizedFileURL
            guard AppPaths.isDirect(url), !candidates.contains(where: { $0.url.path == url.path }) else { return }
            do {
                let stamp = try FileStamp(url)
                candidates.append(
                    RemovalCandidate(
                        url: url, kind: kind, stamp: stamp, bytes: Self.byteCount(url), needsReview: review))
            } catch {
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain
                    && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code)
                {
                    return
                }
                notes.append(L("Could not inspect: {0}", url.path))
                accessIssues.append(RemovalFailure(error, url: url, kind: kind))
            }
        }
        if !appAlreadyRemoved {
            add(app.url, .application)
            guard candidates.count == 1 else { throw StudioError(L("Could not verify this file.")) }
        }
        // Two installations of the same app may share all of their settings and data.
        if try hasInstalledApplication(app.bundleID, excluding: app.url, installed: installed) {
            notes.append(L("Another copy of this app is installed. Shared settings and data are excluded."))
            return RemovalPlan(app: app, candidates: candidates, notes: notes)
        }
        let exact: [(String, RemovalKind, String, Bool)] = [
            ("Caches", .cache, app.bundleID, false),
            ("Preferences", .preferences, app.bundleID + ".plist", false),
            ("Saved Application State", .savedState, app.bundleID + ".savedState", false),
            ("Logs", .logs, app.bundleID, false),
            ("HTTPStorages", .cache, app.bundleID, false),
            ("HTTPStorages", .appData, app.bundleID + ".binarycookies", true),
            ("Cookies", .appData, app.bundleID + ".binarycookies", true),
            ("Application Scripts", .appData, app.bundleID, true),
            ("WebKit", .appData, app.bundleID, true),
            ("Application Support", .appData, app.bundleID, true),
            ("Containers", .appData, app.bundleID, true),
        ]
        for library in libraryRoots {
            for (folder, kind, filename, review) in exact {
                let parent = library.appendingPathComponent(folder)
                guard FileManager.default.fileExists(atPath: parent.path) else { continue }
                do {
                    _ = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                } catch {
                    notes.append(L("Could not inspect: {0}", parent.path))
                    accessIssues.append(RemovalFailure(error, url: parent, kind: kind))
                    continue
                }
                add(parent.appendingPathComponent(filename), kind, review: review)
            }
            let byHost = library.appendingPathComponent("Preferences/ByHost")
            if FileManager.default.fileExists(atPath: byHost.path) {
                do {
                    let files = try FileManager.default.contentsOfDirectory(at: byHost, includingPropertiesForKeys: nil)
                    for file in files {
                        let name = file.lastPathComponent
                        let prefix = app.bundleID + "."
                        guard name.hasPrefix(prefix), name.hasSuffix(".plist") else { continue }
                        let host = String(name.dropFirst(prefix.count).dropLast(6))
                        if UUID(uuidString: host) != nil { add(file, .preferences) }
                    }
                } catch {
                    notes.append(L("Could not inspect: {0}", byHost.path))
                    accessIssues.append(RemovalFailure(error, url: byHost, kind: .preferences))
                }
            }
            // Name-only matches are suggestions, never preselected. Vendor-wide and
            // group-container folders are deliberately not traversed or guessed.
            for name
                in (includeNameMatches
                ? Set([app.name, app.url.deletingPathExtension().lastPathComponent]) : Set<String>())
            {
                guard name.count >= 3, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
                    !installed.contains(where: {
                        $0.bundleID != app.bundleID
                            && ($0.name.caseInsensitiveCompare(name) == .orderedSame
                                || $0.url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name)
                                    == .orderedSame)
                    })
                else { continue }
                add(
                    library.appendingPathComponent("Application Support").appendingPathComponent(name), .appData,
                    review: true)
                add(library.appendingPathComponent("Caches").appendingPathComponent(name), .cache, review: true)
                add(library.appendingPathComponent("Logs").appendingPathComponent(name), .logs, review: true)
            }
        }
        notes = Array(Set(notes)).sorted()
        return RemovalPlan(app: app, candidates: candidates, notes: notes, accessIssues: accessIssues)
    }
    static func byteCount(_ url: URL) -> Int64? {
        let fm = FileManager.default
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { return nil }
        if values.isDirectory != true { return values.fileSize.map(Int64.init) }
        var incomplete = false
        var count = 0
        var size: Int64 = 0
        guard
            let entries = fm.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                errorHandler: { _, _ in
                    incomplete = true
                    return true
                })
        else { return nil }
        for case let file as URL in entries {
            count += 1
            if count > 150_000 { return nil }
            guard let value = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            else {
                incomplete = true
                continue
            }
            if value.isSymbolicLink == true {
                entries.skipDescendants()
                continue
            }
            if value.isRegularFile == true { size += Int64(value.fileSize ?? 0) }
        }
        return incomplete ? nil : size
    }
    func revalidate(_ candidate: RemovalCandidate) throws {
        let allowed = candidate.kind == .application ? applicationRoots : libraryRoots
        guard allowed.contains(where: { AppPaths.contains(candidate.url, in: $0) }),
            AppPaths.isDirect(candidate.url), try FileStamp(candidate.url) == candidate.stamp
        else {
            throw StudioError(L("This file changed. Scan again before removing it."))
        }
    }
}

enum ApplicationRemoval {
    typealias Recycle = (URL) async throws -> URL
    static func validateCompletedApp(_ plan: RemovalPlan, previous: [RemovalOutcome]) throws -> Bool {
        guard let moved = previous.first(where: { $0.originalPath == plan.app.path && $0.trashPath != nil }) else {
            return false
        }
        guard let path = moved.trashPath,
            let expected = plan.candidates.first(where: { $0.kind == .application })?.stamp,
            let actual = try? FileStamp(URL(fileURLWithPath: path)), actual.device == expected.device,
            actual.inode == expected.inode,
            !FileManager.default.fileExists(atPath: plan.app.path)
        else {
            throw StudioError(L("The app or related files changed. Scan again."))
        }
        return true
    }
    static func rescan(_ plan: RemovalPlan, previous: [RemovalOutcome], scanner: RemovalScanner) throws -> RemovalPlan {
        if try validateCompletedApp(plan, previous: previous) {
            let fresh = try scanner.scan(plan.app, appAlreadyRemoved: true)
            guard let original = plan.candidates.first(where: { $0.kind == .application }) else {
                throw StudioError(L("Could not verify this file."))
            }
            return RemovalPlan(
                app: plan.app, candidates: [original] + fresh.candidates, notes: fresh.notes,
                accessIssues: fresh.accessIssues)
        }
        guard let current = ApplicationInventory.read(plan.app.url), current.bundleID == plan.app.bundleID else {
            throw StudioError(L("The app or related files changed. Scan again."))
        }
        return try scanner.scan(current)
    }
    static func recycle(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { destinations, error in
                if let destination = destinations.first(where: {
                    $0.key.standardizedFileURL.path == url.standardizedFileURL.path
                })?.value {
                    continuation.resume(returning: destination)
                } else {
                    continuation.resume(throwing: error ?? StudioError(L("The file was not moved to Trash.")))
                }
            }
        }
    }
    static func isRunning(_ app: InstalledApplication) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == app.bundleID || $0.bundleURL?.path == app.path
                || ($0.executableURL.map { AppPaths.contains($0, in: app.url) } ?? false)
        }
    }
    static func execute(
        _ plan: RemovalPlan, selected: Set<String>, scanner: RemovalScanner,
        running: (InstalledApplication) -> Bool = isRunning,
        recycle: Recycle = recycle,
        previous: [RemovalOutcome] = [], usingFinder: Bool = false,
        finderRecycle: Recycle = { url in try await MainActor.run { try FinderTrash.recycle(url) } },
        checkpoint: (RemovalReceipt) throws -> Void = { _ in }
    ) async throws -> RemovalReceipt {
        try scanner.validateLocation(plan.app)
        let receiptID = UUID()
        let receiptDate = Date()
        let completed = previous.filter { $0.trashPath != nil }
        let completedIDs = Set(completed.map(\.originalPath))
        let appAlreadyRemoved = try validateCompletedApp(plan, previous: completed)
        if !appAlreadyRemoved {
            try scanner.validateApp(plan.app)
            guard ApplicationInventory.read(plan.app.url)?.revision == plan.app.revision else {
                throw StudioError(L("The app or related files changed. Scan again."))
            }
        }
        guard !running(plan.app) else { throw StudioError(L("Quit {0} before removing it.", plan.app.name)) }
        guard selected.contains(plan.app.path), selected.isSubset(of: Set(plan.candidates.map(\.id))) else {
            throw StudioError(L("The removal selection is invalid."))
        }
        // Recompute ownership at confirmation time, including newly installed duplicates.
        let fresh = try scanner.scan(plan.app, appAlreadyRemoved: appAlreadyRemoved)
        let permitted = Dictionary(uniqueKeysWithValues: fresh.candidates.map { ($0.id, $0) })
        let items = plan.candidates.filter { selected.contains($0.id) && !completedIDs.contains($0.id) }
        for item in items {
            guard let current = permitted[item.id], current.kind == item.kind, current.stamp == item.stamp else {
                throw StudioError(L("The app or related files changed. Scan again."))
            }
            try scanner.revalidate(item)
        }
        var outcomes = completed
        func saveProgress() throws {
            let receipt = RemovalReceipt(
                id: receiptID, date: receiptDate, appName: plan.app.name, items: outcomes,
                bundleID: plan.app.bundleID, appFileName: plan.app.url.deletingPathExtension().lastPathComponent)
            do { try checkpoint(receipt) } catch {
                throw RemovalHistoryWriteError(receipt: receipt, remaining: items, underlying: error)
            }
        }
        try saveProgress()
        func validateBeforeMoving(_ item: RemovalCandidate) throws {
            guard !running(plan.app) else { throw StudioError(L("Quit {0} before removing it.", plan.app.name)) }
            if item.kind == .application {
                try scanner.validateApp(plan.app)
                guard ApplicationInventory.read(plan.app.url)?.revision == plan.app.revision else {
                    throw StudioError(L("The app or related files changed. Scan again."))
                }
            } else if try scanner.hasInstalledApplication(plan.app.bundleID) {
                throw StudioError(L("Another copy of this app is installed. Shared settings and data are excluded."))
            }
            try scanner.revalidate(item)
        }
        // The app goes first. If it cannot be removed, its settings remain intact.
        for item in items.sorted(by: {
            ($0.kind == .application ? 0 : 1, $0.id) < ($1.kind == .application ? 0 : 1, $1.id)
        }) {
            do {
                try validateBeforeMoving(item)
                // The user has confirmed these exact files. Protected vendor folders
                // go straight to Finder's authentication flow instead of failing first.
                let destination: URL
                if usingFinder || FinderTrash.needsAuthorization(item.url) {
                    destination = try await finderRecycle(item.url)
                } else {
                    do { destination = try await recycle(item.url) } catch {
                        // Continue the already confirmed removal through macOS authorization.
                        // Cancellation and unrelated errors must never trigger another attempt.
                        guard RemovalFailure(error, url: item.url, kind: item.kind).permitsAutomaticFinderRetry else {
                            throw error
                        }
                        try validateBeforeMoving(item)
                        destination = try await finderRecycle(item.url)
                    }
                }
                outcomes.append(
                    RemovalOutcome(
                        originalPath: item.id, trashPath: destination.path, error: nil, kind: item.kind,
                        trashStamp: try? FileStamp(destination)))
            } catch {
                let failure = RemovalFailure(error, url: item.url, kind: item.kind)
                let message = failure.recovery == .cancelled ? failure.guidance : error.localizedDescription
                outcomes.append(RemovalOutcome(originalPath: item.id, trashPath: nil, error: message, failure: failure))
                if item.kind == .application || failure.recovery == .cancelled || failure.recovery == .automation {
                    try saveProgress()
                    break
                }
            }
            try saveProgress()
        }
        return RemovalReceipt(
            id: receiptID, date: receiptDate, appName: plan.app.name, items: outcomes, bundleID: plan.app.bundleID,
            appFileName: plan.app.url.deletingPathExtension().lastPathComponent)
    }
}
