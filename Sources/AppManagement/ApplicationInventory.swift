import CoreServices
import Foundation

struct InstalledApplication: Codable, Equatable, Identifiable {
    var path: String
    var bundleID: String
    var name: String
    var version: String
    var revision: String
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

enum AppPaths {
    static var applicationRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }
    static func contains(_ child: URL, in parent: URL) -> Bool {
        let parts = child.standardizedFileURL.pathComponents
        let base = parent.standardizedFileURL.pathComponents
        return parts.count > base.count && parts.starts(with: base)
    }
    static func identifierIsSafe(_ value: String) -> Bool {
        value.count <= 255 && value.contains(".") && !value.contains("..")
            && value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }
    // Do not traverse an alias or symlink while locating files for removal.
    static func isDirect(_ url: URL) -> Bool {
        url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

enum ApplicationInventory {
    static func read(_ url: URL) -> InstalledApplication? {
        guard url.pathExtension.lowercased() == "app", AppPaths.isDirect(url),
            let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let bundleID = info["CFBundleIdentifier"] as? String, AppPaths.identifierIsSafe(bundleID),
            let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
            !executable.contains("/"), !executable.contains("\0"), executable != ".", executable != ".."
        else { return nil }
        let binary = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        guard FileManager.default.isExecutableFile(atPath: binary.path),
            let stamp = try? FileStamp(binary),
            let infoStamp = try? FileStamp(url.appendingPathComponent("Contents/Info.plist"))
        else { return nil }
        let name =
            (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApplication(
            path: url.standardizedFileURL.path, bundleID: bundleID, name: name,
            version: info["CFBundleShortVersionString"] as? String ?? "",
            revision: "\(stamp.inode):\(stamp.size):\(stamp.modified):\(infoStamp.modified)")
    }
    static func scan(roots: [URL] = AppPaths.applicationRoots) throws -> [InstalledApplication] {
        let fm = FileManager.default
        var apps: [InstalledApplication] = []
        for rawRoot in roots {
            let root = rawRoot.resolvingSymlinksInPath().standardizedFileURL
            guard fm.fileExists(atPath: root.path) else { continue }
            var directories = [root]
            while let directory = directories.popLast() {
                let entries = try fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                    options: .skipsHiddenFiles)
                for url in entries {
                    // Explicit traversal avoids skipDescendants affecting the next
                    // directory when a dangling .app alias is encountered.
                    guard AppPaths.isDirect(url) else { continue }
                    if url.pathExtension.lowercased() == "app" {
                        if let app = read(url), app.bundleID != "local.launchpadstudio.app" { apps.append(app) }
                    } else {
                        let values = try url.resourceValues(forKeys: [
                            .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                        ])
                        if values.isDirectory == true && values.isSymbolicLink != true && values.isPackage != true {
                            directories.append(url)
                        }
                    }
                }
            }
        }
        return Dictionary(grouping: apps, by: \.path).compactMap { $0.value.first }.sorted { $0.path < $1.path }
    }
}

struct AppDiscoveryState: Codable, Equatable {
    var initialized = false
    var known: Set<String> = []
    var pending: Set<String> = []
    var names: [String: String]? = nil

    mutating func reconcile(_ apps: [InstalledApplication]) -> Set<String> {
        let installed = Set(apps.map(\.bundleID))
        var labels = names ?? [:]
        for app in apps { labels[app.bundleID] = app.name }
        names = labels
        let added = initialized ? installed.subtracting(known) : []
        pending.formUnion(added)
        known.formUnion(installed)  // Keep identities through an app updater's remove/replace cycle.
        initialized = true
        return added
    }
}

// Filesystem events are coalesced, then confirmed by a second inventory. A periodic
// rescan also covers missed events and applications installed while Studio was closed.
final class ApplicationMonitor {
    private let roots: [URL]
    private let receive: (Result<[InstalledApplication], Error>) -> Void
    private let queue = DispatchQueue(label: "local.launchpadstudio.inventory", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var work: DispatchWorkItem?
    private var stopped = true
    private var confirming = false
    private var refreshPending = false
    init(roots: [URL], receive: @escaping (Result<[InstalledApplication], Error>) -> Void) {
        self.roots = roots
        self.receive = receive
        queue.setSpecific(key: queueKey, value: true)
    }
    func start() {
        queue.async { [weak self] in
            guard let self, self.stopped else { return }
            self.stopped = false
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                copyDescription: nil)
            // Watch the home folder if ~/Applications does not exist yet.
            let paths = self.roots.map {
                FileManager.default.fileExists(atPath: $0.path) ? $0.path : $0.deletingLastPathComponent().path
            }
            self.stream = FSEventStreamCreate(
                nil,
                { _, info, _, paths, _, _ in
                    guard let info else { return }
                    let monitor = Unmanaged<ApplicationMonitor>.fromOpaque(info).takeUnretainedValue()
                    let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
                    if changed.contains(where: { path in
                        monitor.roots.contains {
                            URL(fileURLWithPath: path).standardizedFileURL.path == $0.standardizedFileURL.path
                                || AppPaths.contains(URL(fileURLWithPath: path), in: $0)
                        }
                    }) {
                        monitor.schedule(after: 6)
                    }
                }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
            if let stream = self.stream {
                FSEventStreamSetDispatchQueue(stream, self.queue)
                FSEventStreamStart(stream)
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
            timer.setEventHandler { [weak self] in self?.schedule(after: 0) }
            timer.resume()
            self.timer = timer
            self.schedule(after: 0)
        }
    }
    func refresh() { queue.async { [weak self] in self?.schedule(after: 0) } }
    private func schedule(after delay: TimeInterval) {
        guard !stopped else { return }
        // Metadata events can continue after installation. Let an in-flight pair
        // finish so they cannot indefinitely postpone the initial inventory.
        guard !confirming else {
            refreshPending = true
            return
        }
        work?.cancel()
        let next = DispatchWorkItem { [weak self] in self?.confirmInventory() }
        work = next
        queue.asyncAfter(deadline: .now() + delay, execute: next)
    }
    private func confirmInventory() {
        guard !stopped else { return }
        confirming = true
        do {
            let first = try ApplicationInventory.scan(roots: roots)
            let confirmation = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped else { return }
                defer { self.finishConfirmation() }
                do {
                    let second = try ApplicationInventory.scan(roots: self.roots)
                    guard first == second else {
                        self.refreshPending = true
                        return
                    }
                    DispatchQueue.main.async { self.receive(.success(second)) }
                } catch { DispatchQueue.main.async { self.receive(.failure(error)) } }
            }
            work = confirmation
            queue.asyncAfter(deadline: .now() + 3, execute: confirmation)
        } catch {
            DispatchQueue.main.async { self.receive(.failure(error)) }
            finishConfirmation()
        }
    }
    private func finishConfirmation() {
        confirming = false
        if refreshPending {
            refreshPending = false
            schedule(after: 6)
        }
    }
    func stop() {
        let finish = {
            self.stopped = true
            self.work?.cancel()
            self.work = nil
            self.timer?.cancel()
            self.timer = nil
            self.confirming = false
            self.refreshPending = false
            if let stream = self.stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            self.stream = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { finish() } else { queue.sync(execute: finish) }
    }
    deinit { stop() }
}
