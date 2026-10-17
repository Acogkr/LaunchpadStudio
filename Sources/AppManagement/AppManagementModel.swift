import AppKit
import Foundation

extension StudioModel {
    var newApplications: [InstalledApplication] {
        var seen = Set<String>()
        let arranged = Set(folders.flatMap(\.appIDs).compactMap { app($0)?.bundleID })
        return installedApplications.filter {
            discovery.pending.contains($0.bundleID) && !arranged.contains($0.bundleID)
                && seen.insert($0.bundleID).inserted
        }
        .sorted { L10n.ordered($0.name, $1.name) }
    }
    func loadDiscovery() {
        let file = dataRoot.appendingPathComponent("app-discovery.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { discovery = try JSONDecoder().decode(AppDiscoveryState.self, from: Data(contentsOf: file)) } catch {
            _ = try? preserveFile(file, in: "Recovered App History")
            inventoryIssue = L("App detection history was reset. Existing apps will not be announced again.")
        }
    }
    func saveDiscovery() {
        do {
            try JSONEncoder().encode(discovery).write(
                to: dataRoot.appendingPathComponent("app-discovery.json"), options: .atomic)
            discoveryNeedsSave = false
            inventoryIssue = nil
        } catch {
            discoveryNeedsSave = true
            inventoryIssue = L("Could not save app detection history: {0}", error.localizedDescription)
        }
    }
    func startApplicationMonitor() {
        guard applicationMonitor == nil else { return }
        applicationMonitor = ApplicationMonitor(roots: removalScanner.applicationRoots) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let apps): self.receiveApplications(apps)
            case .failure(let error): self.inventoryIssue = error.localizedDescription
            }
        }
        applicationMonitor?.start()
        launchpadMonitor = LaunchpadMonitor(model: self)
        launchpadMonitor?.start()
    }
    func receiveApplications(_ installed: [InstalledApplication]) {
        let catalogChanged = installedApplications != installed
        installedApplications = installed
        inventoryIssue = nil
        let before = discovery
        let added = discovery.reconcile(installed)
        if before != discovery || discoveryNeedsSave { saveDiscovery() }
        reconcileLaunchpadCatalog()
        if waitingForNewAppRegistration { reviewNewApplications() }
        if !added.isEmpty { newAppToast = !newApplications.isEmpty }
        if newApplications.isEmpty { newAppToast = false }
        if catalogChanged {
            for delay in [2.0, 6.0, 15.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.reconcileLaunchpadCatalog()
                }
            }
        }
    }
    func reviewNewApplications() {
        selectedTab = "preview"
        search = ""
        let identifiers = Set(newApplications.map(\.bundleID))
        guard !identifiers.isEmpty else {
            waitingForNewAppRegistration = false
            newAppToast = false
            return
        }
        for (page, layoutPage) in layout.pages.enumerated() {
            for tile in layoutPage.tiles {
                if let id = tile.appIDs.first(where: { app($0).map { identifiers.contains($0.bundleID) } == true }) {
                    pageIndex = page
                    selectedTile = tile.id
                    selectedApp = id
                    waitingForNewAppRegistration = false
                    newAppToast = false
                    notice = ""
                    return
                }
            }
        }
        notice = L("Waiting for Launchpad registration…")
        waitingForNewAppRegistration = true
    }
    func acknowledgeApplication(_ bundleID: String) {
        discovery.pending.remove(bundleID)
        saveDiscovery()
        if newApplications.isEmpty { newAppToast = false }
    }
    // Rebase the working layout and its undo history on the new Launchpad catalog.
    // This reads the database only; installing/removing an app never triggers Apply.
    @discardableResult func reconcileLaunchpadCatalog() -> Bool {
        guard !busy else { return false }
        guard let old = baseline, let source else {
            do {
                try load()
                return true
            } catch { return false }
        }
        let candidate: URL
        if FileManager.default.fileExists(atPath: source.path) {
            candidate = source
        } else {
            guard let relocated = try? locateSource() else { return false }
            candidate = relocated
        }
        guard let fresh = try? LaunchpadStore.snapshot(candidate.path) else { return false }
        guard fresh.fingerprint != old.fingerprint || candidate != source else { return true }
        let hadChanges = hasChanges
        let hadConflict = syncConflict
        let previousLayout = layout
        let previousUndo = undoStack
        let previousRedo = redoStack
        let previousTile = selectedTile
        let previousApp = selectedApp
        let previousPage = pageIndex
        let previousNotice = notice
        let previousRestore = pendingRestoreName
        let previousError = error
        do {
            var draft = Draft(snapshot: old, layout: previousLayout)
            draft.syncConflict = hadConflict
            try load(preserving: hadChanges || hadConflict ? draft : nil)
            guard let current = baseline else { return false }
            // Redo can exist even after every edit was undone. Keep it through
            // catalog-only updates, but not when adopting an external arrangement.
            let known = Set(old.apps.map { $0.uuid + "|" + $0.bundleID })
            let surviving = Set(apps.filter { known.contains($0.uuid + "|" + $0.bundleID) }.map(\.id))
            let rebasedBase = try? Draft(snapshot: old, layout: old.layout).restored(for: current, apps: apps)
            let keepHistory =
                hadChanges || rebasedBase?.arrangement(of: surviving) == current.layout.arrangement(of: surviving)
            undoStack = (keepHistory ? previousUndo : []).compactMap {
                try? Draft(snapshot: old, layout: $0).restored(for: current, apps: apps)
            }
            redoStack = (keepHistory ? previousRedo : []).compactMap {
                try? Draft(snapshot: old, layout: $0).restored(for: current, apps: apps)
            }
            let byUUID = Dictionary(grouping: apps, by: \.uuid)
            func remap(_ id: Int64) -> Int64? {
                guard let prior = old.apps.first(where: { $0.id == id }), let matches = byUUID[prior.uuid],
                    matches.count == 1, matches[0].bundleID == prior.bundleID
                else { return nil }
                return matches[0].id
            }
            selectedTile = previousTile
            if let prior = previousLayout.tiles.first(where: { $0.id == previousTile }), !prior.isFolder,
                let id = prior.appIDs.first.flatMap(remap)
            {
                selectedTile = "app-\(id)"
            }
            selectedApp = previousApp.flatMap(remap)
            pageIndex = previousPage
            pendingRestoreName = previousRestore
            normalizeSelection()
            notice = previousNotice
            if !hasUnsavedChanges { error = previousError }
            if waitingForNewAppRegistration { reviewNewApplications() }
            return true
        } catch {
            // A download or Dock transaction can temporarily make the snapshot unreadable.
            // Keep the current draft and retry after the next filesystem scan.
            self.error = previousError
            return false
        }
    }
    func removalApp(for id: Int64) -> InstalledApplication? {
        guard let record = app(id) else { return nil }
        if let path = record.path, let installed = ApplicationInventory.read(URL(fileURLWithPath: path)),
            installed.bundleID == record.bundleID, (try? removalScanner.validateApp(installed)) != nil
        {
            return installed
        }
        let matches = installedApplications.filter { $0.bundleID == record.bundleID }
        guard matches.count == 1, let installed = matches.first,
            (try? removalScanner.validateApp(installed)) != nil
        else { return nil }
        return installed
    }
    func prepareRemoval(_ app: InstalledApplication) {
        guard !busy else { return }
        guard !isDeletionProtected(app.bundleID) else {
            error = L("This app is protected from deletion.")
            return
        }
        removalTarget = app
        removalPlan = nil
        removalReceipt = nil
        removalCompleted = []
        removalError = nil
        removalFailure = nil
        removalSelection = []
        scanRemoval()
    }
    func scanRemoval() {
        guard !busy, let target = removalTarget else { return }
        let scanID = UUID()
        removalScanID = scanID
        let previousSelection = removalPlan == nil ? nil : removalSelection
        let previousPlan = removalPlan
        let completed = (removalReceipt?.items ?? removalCompleted).filter { $0.trashPath != nil }
        removalCompleted = completed
        removalScanning = true
        removalError = nil
        removalFailure = nil
        removalReceipt = nil
        let scanner = removalScanner
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                if let previousPlan {
                    return try ApplicationRemoval.rescan(previousPlan, previous: completed, scanner: scanner)
                }
                guard let current = ApplicationInventory.read(target.url), current.bundleID == target.bundleID else {
                    throw StudioError(L("The app or related files changed. Scan again."))
                }
                return try scanner.scan(current)
            }
            DispatchQueue.main.async {
                guard self.removalScanID == scanID, self.removalTarget?.path == target.path else { return }
                self.removalScanning = false
                switch result {
                case .success(let plan):
                    self.removalTarget = plan.app
                    self.removalPlan = plan
                    self.removalSelection =
                        previousSelection.map { $0.intersection(Set(plan.candidates.map(\.id))) }
                        ?? Set(plan.candidates.filter(\.selectedByDefault).map(\.id))
                case .failure(let error):
                    self.removalError = error.localizedDescription
                    self.removalFailure = RemovalFailure(error, url: target.url, kind: .application)
                }
            }
        }
    }
    func closeRemoval() {
        guard !busy else { return }
        retryRemovalReceiptSaves()
        removalScanID = UUID()
        removalScanning = false
        removalTarget = nil
    }
    func quitRemovalTarget() {
        guard let target = removalTarget else { return }
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == target.bundleID || app.bundleURL?.path == target.path {
            app.terminate()  // The app can refuse or ask the user to save. Never force quit.
        }
    }
    var removalAccessIssue: RemovalFailure? {
        removalFailure ?? removalReceipt?.items.compactMap(\.failure).first
            ?? (removalReceipt == nil ? removalPlan?.accessIssues.first : nil)
    }
    func removeSelectedFiles(usingFinder: Bool = false) {
        guard !busy, let plan = removalPlan, removalSelection.contains(plan.app.path) else { return }
        busyText = L("Moving to Trash…")
        busy = true
        removalError = nil
        removalFailure = nil
        guard !isDeletionProtected(plan.app.bundleID) else {
            busy = false
            removalError = L("This app is protected from deletion.")
            return
        }
        let selected = removalSelection
        let scanner = protectedRemovalScanner
        let previous = removalReceipt?.items ?? removalCompleted
        let history = RemovalHistory(root: dataRoot.appendingPathComponent("Removal History"))
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    return Result<RemovalReceipt, Error>.success(
                        try await ApplicationRemoval.execute(
                            plan, selected: selected, scanner: scanner, previous: previous, usingFinder: usingFinder,
                            checkpoint: history.save))
                } catch { return Result<RemovalReceipt, Error>.failure(error) }
            }.value
            await MainActor.run {
                self.busy = false
                switch result {
                case .success(let receipt):
                    self.showRemovalResult(receipt)
                case .failure(let error):
                    if let interrupted = error as? RemovalHistoryWriteError {
                        self.showRemovalResult(interrupted.receipt, issue: interrupted.localizedDescription)
                    } else {
                        self.removalError = error.localizedDescription
                        self.removalFailure = RemovalFailure(error, url: plan.app.url, kind: .application)
                    }
                }
            }
        }
    }
    func showRemovalResult(_ receipt: RemovalReceipt, issue: String? = nil) {
        removalReceipt = receipt
        removalError = issue
        removalFailure = nil
        if !recordRemovalReceipt(receipt) {
            removalError = issue ?? L("Files were moved, but the removal history could not be saved.")
        }
        if let plan = removalPlan,
            receipt.items.contains(where: { $0.originalPath == plan.app.path && $0.trashPath != nil })
        {
            acknowledgeApplication(plan.app.bundleID)
        }
        applicationMonitor?.refresh()
        reconcileLaunchpadCatalog()
    }
}
