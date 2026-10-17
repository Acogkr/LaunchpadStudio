import AppKit
import Foundation

enum LiveApply {
    static func apply(_ layout: Layout, baseline: Snapshot, source: URL, backups: BackupManager, reason: String) throws
        -> BackupRecord
    {
        try PlatformSupport.requireSupportedOS()
        let dockSettings = UserDefaults.standard.persistentDomain(forName: "com.apple.dock") ?? [:]
        let columns = (dockSettings["springboard-columns"] as? NSNumber)?.intValue ?? 7
        let rows = (dockSettings["springboard-rows"] as? NSNumber)?.intValue ?? 5
        guard columns == 7, rows == 5 else {
            throw StudioError(
                L(
                    "Custom Launchpad grids ({0}×{1}) are not supported. Preview and backup are still available.",
                    columns, rows))
        }
        guard try LaunchpadStore.locate().resolvingSymlinksInPath() == source.resolvingSymlinksInPath() else {
            throw StudioError(L("The Launchpad path does not match the current user."))
        }
        try layout.validated(for: baseline.apps)
        let backup = try backups.create(source: source, reason: reason)
        let backupSnapshot = try backups.read(backup)
        guard backupSnapshot.fingerprint == baseline.fingerprint else {
            throw StudioError(L("Launchpad changed since this preview was created. Refresh before applying."))
        }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            throw StudioError(L("Could not find the Dock process."))
        }
        let pid = dock.processIdentifier
        // Resume only after an unexpected owner exit, never on a timer during a slow write.
        let watchdog = try ApplyWatchdog.start(owner: ProcessInfo.processInfo.processIdentifier, target: pid)
        defer {
            if !dock.isTerminated { _ = kill(pid, SIGCONT) }
            if watchdog.isRunning { watchdog.terminate() }
        }
        guard kill(pid, SIGSTOP) == 0 else { throw StudioError(L("Could not pause Dock.")) }
        let db = try Database(source.path, writable: true)
        try db.execute("BEGIN IMMEDIATE")
        do {
            try LaunchpadStore.write(layout, to: db, baseline: baseline)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        // Killing the stopped Dock prevents stale in-memory state overwriting the transaction.
        guard kill(pid, SIGKILL) == 0 else {
            throw StudioError(
                L("The layout was saved, but Dock could not restart. Sign out and check, or restore a backup."))
        }
        var stableReads = 0
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.4)
            let restarted = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").contains {
                $0.processIdentifier != pid
            }
            if restarted, let actual = try? LaunchpadStore.snapshot(source.path),
                actual.layout.semantic == layout.semantic
            {
                stableReads += 1
                if stableReads >= 3 { return backup }
            } else {
                stableReads = 0
            }
        }
        throw StudioError(
            L(
                "The layout was saved, but could not be verified after Dock restarted. Check Launchpad. The previous layout is available in Backups."
            ))
    }
}
