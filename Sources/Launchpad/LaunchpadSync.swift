import AppKit

// A cheap metadata check also catches SQLite WAL updates and database replacement.
// Failed reads keep the previous signature so the next tick retries automatically.
final class LaunchpadMonitor {
    private weak var model: StudioModel?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var signature = ""
    init(model: StudioModel) { self.model = model }
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh(force: true) }
    }
    func refresh(force: Bool = false) {
        guard let model else { return }
        let current = [model.source?.path, model.source.map { $0.path + "-wal" }].compactMap { $0 }.map { path in
            let stamp = try? FileStamp(URL(fileURLWithPath: path))
            return "\(path):\(String(describing: stamp))"
        }.joined(separator: "|")
        if force || model.baseline == nil || current != signature {
            if model.reconcileLaunchpadCatalog() { signature = current }
        }
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }
    deinit { stop() }
}

extension StudioModel {
    func resolveSyncConflict(keepEdits: Bool) {
        guard !busy else { return }
        if keepEdits {
            guard reconcileLaunchpadCatalog() else {
                error = L("Could not read Launchpad")
                return
            }
            syncConflict = false
            saveDraft()
        } else {
            perform {
                try load()
                showApply = false
            }
        }
    }
    func isDeletionProtected(_ bundleID: String) -> Bool {
        bundleID == removalScanner.protectedBundleID || preferences.deletionProtected.contains(bundleID)
    }
    var protectedRemovalScanner: RemovalScanner {
        var scanner = removalScanner
        scanner.deletionProtected = preferences.deletionProtected
        return scanner
    }
    func toggleDeletionProtection(_ bundleID: String) {
        guard !busy, bundleID != removalScanner.protectedBundleID else { return }
        if preferences.deletionProtected.contains(bundleID) {
            preferences.deletionProtected.remove(bundleID)
        } else {
            preferences.deletionProtected.insert(bundleID)
        }
        savePreferences()
    }
}
