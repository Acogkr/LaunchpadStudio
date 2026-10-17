import AppKit
import Carbon
import Foundation

func runAppManagementTests() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
        "StudioAppTests-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? fm.removeItem(at: root)
        L10n.testCode = nil
    }
    L10n.testCode = "en"
    var checks = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw StudioError(message) }
        checks += 1
        print("PASS \(checks): \(message)")
    }
    func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch {
            try check(true, message)
            return
        }
        throw StudioError("Expected rejection: " + message)
    }
    func file(_ path: URL, text: String = "fixture data") throws {
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: path)
    }
    let applications = root.appendingPathComponent("Applications")
    let library = root.appendingPathComponent("Library")
    try fm.createDirectory(at: library, withIntermediateDirectories: true)
    let app = try makeFixtureApplication(applications, name: "Paper Notes", bundleID: "org.example.paper")
    let scanner = RemovalScanner(
        applicationRoots: [applications], libraryRoots: [library], registeredApplications: { _ in [] })
    try check(
        try ApplicationInventory.scan(roots: [applications]) == [app], "Inventory recognizes a complete application")
    try file(applications.appendingPathComponent("Incomplete.app/Contents/Info.plist"), text: "unfinished")
    try check(
        try ApplicationInventory.scan(roots: [applications]).count == 1, "Incomplete installations are not announced")
    let helper = try makeFixtureApplication(
        app.url.appendingPathComponent("Contents/Helpers"), name: "Helper", bundleID: "org.example.helper")
    try check(
        try ApplicationInventory.scan(roots: [applications]).count == 1,
        "Embedded helpers are not separate installed apps")
    let nested = try makeFixtureApplication(
        applications.appendingPathComponent("Utilities"), name: "Pencil", bundleID: "org.example.pencil")
    try check(
        try ApplicationInventory.scan(roots: [applications]).count == 2,
        "Applications in ordinary subfolders are detected")
    try fm.createSymbolicLink(at: applications.appendingPathComponent("Alias.app"), withDestinationURL: app.url)
    try check(
        try ApplicationInventory.scan(roots: [applications]).count == 2, "Symbolic aliases do not duplicate app records"
    )
    try check(
        !AppPaths.contains(root.appendingPathComponent("Applications Elsewhere/Fake.app"), in: applications),
        "Path boundaries do not accept a sibling with a matching prefix")
    try check(
        !AppPaths.identifierIsSafe("org.example/../../Documents") && !AppPaths.identifierIsSafe("../../Documents")
            && !AppPaths.identifierIsSafe("org.example.*"),
        "Bundle identifiers cannot escape paths or introduce wildcards")

    var state = AppDiscoveryState()
    try check(
        state.reconcile([app]).isEmpty && state.pending.isEmpty, "The first launch silently records existing apps")
    try check(state.reconcile([app, nested]) == [nested.bundleID], "A newly installed app is announced exactly once")
    try check(state.reconcile([app, nested]).isEmpty, "Repeated scans cannot duplicate notifications")
    var updated = nested
    updated.version = "2.0"
    updated.revision = "new"
    updated.path += ".renamed"
    try check(state.reconcile([app, updated]).isEmpty, "App updates and moves preserve identity")
    _ = state.reconcile([app])
    try check(
        state.reconcile([app, nested]).isEmpty && state.pending.contains(nested.bundleID),
        "An updater's temporary removal does not lose pending review or reannounce the app")
    let saved = try JSONEncoder().encode(state)
    var restarted = try JSONDecoder().decode(AppDiscoveryState.self, from: saved)
    try check(
        restarted.reconcile([app, nested]).isEmpty && restarted.pending == state.pending,
        "Detection and review state survive restart")
    let legacy = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
    try check(
        legacy.rules.isEmpty && legacy.locked.isEmpty,
        "Existing preferences remain compatible without extra feature settings")

    let cache = library.appendingPathComponent("Caches/" + app.bundleID)
    let prefs = library.appendingPathComponent("Preferences/" + app.bundleID + ".plist")
    let support = library.appendingPathComponent("Application Support/" + app.name)
    let container = library.appendingPathComponent("Containers/" + app.bundleID)
    let shared = library.appendingPathComponent("Group Containers/group.org.example")
    let unrelated = library.appendingPathComponent("Caches/" + app.bundleID + ".other")
    try file(cache.appendingPathComponent("cache.bin"))
    try file(prefs)
    try file(support.appendingPathComponent("Important project.txt"))
    try file(container.appendingPathComponent("Data/Documents/Important document.txt"))
    try file(shared.appendingPathComponent("shared.txt"))
    try file(unrelated.appendingPathComponent("unrelated.txt"))
    let namedCache = library.appendingPathComponent("Caches/" + app.name)
    let namedLogs = library.appendingPathComponent("Logs/" + app.name)
    let httpCookies = library.appendingPathComponent("HTTPStorages/" + app.bundleID + ".binarycookies")
    try file(namedCache.appendingPathComponent("cache.bin"))
    try file(namedLogs.appendingPathComponent("app.log"))
    try file(httpCookies)
    let byHost = library.appendingPathComponent(
        "Preferences/ByHost/" + app.bundleID + "." + UUID().uuidString + ".plist")
    try file(byHost)
    try file(library.appendingPathComponent("Preferences/ByHost/" + app.bundleID + ".another-app.plist"))
    var plan = try scanner.scan(app)
    let selected = Set(plan.candidates.filter(\.selectedByDefault).map(\.id))
    try check(
        selected.contains(app.path) && selected.contains(cache.path) && selected.contains(prefs.path),
        "The app, exact cache and preferences are selected")
    try check(
        plan.candidates.contains { $0.url.path == support.path && $0.needsReview } && !selected.contains(support.path),
        "Name-matched application data requires explicit review")
    try check(
        plan.candidates.contains { $0.url.path == container.path && $0.needsReview }
            && !selected.contains(container.path), "Sandbox documents are never selected automatically")
    try check(
        !plan.candidates.contains { $0.url.path == shared.path || $0.url.path == unrelated.path },
        "Group containers and prefix-similar app files are excluded")
    try check(
        [namedCache, namedLogs, httpCookies].allSatisfy { path in
            plan.candidates.contains { $0.id == path.path && $0.needsReview }
        }, "AppCleaner comparison: name-based caches, logs and HTTP cookies are found for review")
    try check(
        !selected.contains(namedCache.path) && !selected.contains(namedLogs.path)
            && !selected.contains(httpCookies.path), "Name-based matches and cookie data require explicit selection")
    try check(
        plan.candidates.filter { $0.url.deletingLastPathComponent().lastPathComponent == "ByHost" }.map(\.id) == [
            byHost.path
        ], "ByHost preferences require an exact identifier and a real UUID")
    let external = root.appendingPathComponent("Personal Documents")
    try file(external.appendingPathComponent("keep.txt"))
    try fm.createDirectory(at: library.appendingPathComponent("Logs"), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: library.appendingPathComponent("Logs/" + app.bundleID), withDestinationURL: external)
    try check(
        !(try scanner.scan(app)).candidates.contains {
            $0.id == library.appendingPathComponent("Logs/" + app.bundleID).path
        }, "Related-file scanning does not follow symbolic links")
    try rejects("Nested helper apps cannot be uninstalled independently") { try scanner.validateApp(helper) }
    var forged = app
    forged.path = root.appendingPathComponent("Outside.app").path
    try rejects("Apps outside the allowed roots cannot be removed") { try scanner.validateApp(forged) }
    var protectedScanner = scanner
    protectedScanner.protectedBundleID = app.bundleID
    try rejects("Launchpad Studio cannot remove itself during an operation") { try protectedScanner.validateApp(app) }

    let duplicate = try makeFixtureApplication(applications, name: "Paper Copy", bundleID: app.bundleID)
    try check(
        try scanner.scan(app).candidates.count == 1, "A duplicate installed app protects shared preferences and data")
    try fm.removeItem(at: duplicate.url)
    let outsideCopy = try makeFixtureApplication(
        root.appendingPathComponent("Elsewhere"), name: "Paper Outside", bundleID: app.bundleID)
    var externalScanner = scanner
    externalScanner.registeredApplications = { _ in [app.url, outsideCopy.url] }
    try check(
        try externalScanner.scan(app).candidates.map(\.id) == [app.path],
        "Registered copies outside Applications exclude shared data from removal")
    var staleRegistryScanner = scanner
    staleRegistryScanner.registeredApplications = { _ in [app.url, root.appendingPathComponent("Missing.app")] }
    try check(
        try staleRegistryScanner.scan(app).candidates.count == scanner.scan(app).candidates.count,
        "The selected app and stale registrations are not mistaken for other installations")
    let sameName = try makeFixtureApplication(
        applications.appendingPathComponent("Other"), name: app.name, bundleID: "org.unrelated.paper")
    try check(
        !(try scanner.scan(app)).candidates.contains { $0.url.path == support.path },
        "Ambiguous application names cannot claim another app's support folder")
    try check(
        !(try scanner.scan(app)).candidates.contains { $0.id == namedCache.path || $0.id == namedLogs.path },
        "Apps with the same name cannot claim each other's caches or logs")
    try fm.removeItem(at: sameName.url)
    let linkedPlan = try scanner.scan(app)
    try fm.moveItem(at: prefs, to: root.appendingPathComponent("Original Preferences"))
    try fm.createSymbolicLink(at: prefs, withDestinationURL: external.appendingPathComponent("keep.txt"))
    try rejects("A file replaced by a link after preview cannot be removed") {
        try scanner.revalidate(linkedPlan.candidates.first { $0.id == prefs.path }!)
    }
    try fm.removeItem(at: prefs)
    try fm.moveItem(at: root.appendingPathComponent("Original Preferences"), to: prefs)

    let safeRecycler: ApplicationRemoval.Recycle = { url in
        guard AppPaths.contains(url, in: root) else { throw StudioError("Test attempted a non-fixture write") }
        let trash = root.appendingPathComponent("Test Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let target = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try fm.moveItem(at: url, to: target)
        return target
    }
    plan = try scanner.scan(app)
    let originalPlan = plan
    try rejects("An external copy discovered after preview blocks removal of shared data") {
        _ = try finishAsync {
            try await ApplicationRemoval.execute(
                originalPlan, selected: selected, scanner: externalScanner, running: { _ in false },
                recycle: safeRecycler)
        }
    }
    let appOnly = try finishAsync {
        try await ApplicationRemoval.execute(
            externalScanner.scan(app), selected: [app.path], scanner: externalScanner, running: { _ in false },
            recycle: safeRecycler)
    }
    try check(
        !appOnly.hasFailures && appOnly.items.count == 1 && fm.fileExists(atPath: prefs.path)
            && fm.fileExists(atPath: outsideCopy.path),
        "Removing one copy keeps the other copy and shared preferences intact")
    try fm.moveItem(at: URL(fileURLWithPath: appOnly.items[0].trashPath!), to: app.url)
    var exposeExternalCopy = false
    var lateExternalScanner = scanner
    lateExternalScanner.registeredApplications = { _ in exposeExternalCopy ? [outsideCopy.url] : [] }
    let lateExternal = try finishAsync {
        try await ApplicationRemoval.execute(
            originalPlan, selected: selected, scanner: lateExternalScanner, running: { _ in false },
            recycle: { url in
                let destination = try await safeRecycler(url)
                if url.path == app.path { exposeExternalCopy = true }
                return destination
            })
    }
    try check(
        lateExternal.items.filter { $0.trashPath != nil }.count == 1 && lateExternal.hasFailures
            && fm.fileExists(atPath: prefs.path) && fm.fileExists(atPath: cache.path),
        "A copy appearing after the app is moved still protects every remaining shared file")
    try fm.moveItem(at: URL(fileURLWithPath: lateExternal.items.first { $0.trashPath != nil }!.trashPath!), to: app.url)
    try fm.removeItem(at: outsideCopy.url)
    let lateDuplicate = try makeFixtureApplication(applications, name: "Later Copy", bundleID: app.bundleID)
    try rejects("Installing a second copy after preview cancels related-file removal") {
        _ = try finishAsync {
            try await ApplicationRemoval.execute(
                originalPlan, selected: selected, scanner: scanner, running: { _ in false }, recycle: safeRecycler)
        }
    }
    try fm.removeItem(at: lateDuplicate.url)
    try rejects("Running apps are rejected before any file is moved") {
        _ = try finishAsync {
            try await ApplicationRemoval.execute(
                originalPlan, selected: selected, scanner: scanner, running: { _ in true }, recycle: safeRecycler)
        }
    }
    try check(
        fm.fileExists(atPath: app.path) && fm.fileExists(atPath: prefs.path),
        "Running-app rejection leaves all files in place")
    try rejects("Injected paths cannot be appended to a removal selection") {
        _ = try finishAsync {
            try await ApplicationRemoval.execute(
                originalPlan, selected: selected.union([external.path]), scanner: scanner, running: { _ in false },
                recycle: safeRecycler)
        }
    }
    try file(prefs, text: "Changed after preview")
    try rejects("Files changed after preview require a new scan") {
        _ = try finishAsync {
            try await ApplicationRemoval.execute(
                originalPlan, selected: selected, scanner: scanner, running: { _ in false }, recycle: safeRecycler)
        }
    }
    let failurePlan = try scanner.scan(app)
    let failed = try finishAsync {
        try await ApplicationRemoval.execute(
            failurePlan, selected: Set(failurePlan.candidates.filter(\.selectedByDefault).map(\.id)), scanner: scanner,
            running: { _ in false }, recycle: { _ in throw StudioError("Permission denied") })
    }
    try check(
        failed.items.count == 1 && failed.items[0].originalPath == app.path && fm.fileExists(atPath: prefs.path),
        "Failure to trash the app leaves every related file untouched")
    let appBeforeUpdate = try scanner.scan(app)
    let updatedApp = try makeFixtureApplication(applications, name: app.name, bundleID: app.bundleID, version: "2.0")
    try rejects("An app replaced by an updater requires a fresh confirmation") {
        _ = try finishAsync {
            try await ApplicationRemoval.execute(
                appBeforeUpdate, selected: [app.path], scanner: scanner, running: { _ in false }, recycle: safeRecycler)
        }
    }
    let finalPlan = try scanner.scan(updatedApp)
    let receipt = try finishAsync {
        try await ApplicationRemoval.execute(
            finalPlan, selected: Set(finalPlan.candidates.filter(\.selectedByDefault).map(\.id)), scanner: scanner,
            running: { _ in false },
            recycle: { url in
                if url.path == prefs.path { throw StudioError("Permission denied") }
                return try await safeRecycler(url)
            })
    }
    try check(
        receipt.items.first?.originalPath == app.path && receipt.items.first?.trashPath != nil,
        "The app is moved before its related files")
    try check(
        receipt.items.contains { $0.originalPath == prefs.path && $0.error != nil }
            && fm.fileExists(atPath: prefs.path), "Partial failures report the exact file that remains")
    try check(
        !fm.fileExists(atPath: cache.path) && fm.fileExists(atPath: support.path)
            && fm.fileExists(atPath: container.path), "Selected cache is removed while unselected user data survives")
    try check(
        fm.fileExists(atPath: external.appendingPathComponent("keep.txt").path) && fm.fileExists(atPath: shared.path)
            && fm.fileExists(atPath: unrelated.path), "Personal files, shared data and unrelated apps survive removal")
    try check(
        try JSONDecoder().decode(RemovalReceipt.self, from: JSONEncoder().encode(receipt)).items.count
            == receipt.items.count, "Removal history can preserve partial results and Trash locations")

    let denied = NSError(
        domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
    let access = RemovalFailure(denied, url: prefs, kind: .preferences)
    try check(
        access.recovery == .fileAccess && access.underlyingCode == Int(EPERM),
        "Permission recovery uses error codes and preserves the underlying cause")
    try check(
        RemovalFailure(denied, url: app.url, kind: .application).recovery == .appManagement,
        "An app access failure offers App Management recovery")
    try check(
        RemovalFailure(NSError(domain: NSOSStatusErrorDomain, code: -1743), url: prefs, kind: .preferences).recovery
            == .automation, "Finder automation denial has its own recovery")
    try check(
        RemovalFailure(NSError(domain: NSOSStatusErrorDomain, code: -128), url: prefs, kind: .preferences).recovery
            == .cancelled, "Cancelling authentication is not reported as a permission denial")
    try check(
        !RemovalFailure(StudioError("Permission denied"), url: prefs, kind: .preferences).permitsFinderRetry,
        "Error text alone cannot trigger an authorization retry")
    let appAccess = RemovalFailure(denied, url: app.url, kind: .application)
    let finderAccess = RemovalFailure(
        NSError(domain: NSOSStatusErrorDomain, code: -1743), url: prefs, kind: .preferences)
    try check(
        appAccess.settingsURL == nil && appAccess.permitsAutomaticFinderRetry,
        "App access failures continue through Finder instead of requiring manual App Management registration")
    try check(
        finderAccess.settingsURL?.absoluteString.hasSuffix("?Privacy_Automation") == true,
        "Finder permission recovery opens Automation directly")
    try check(
        access.settingsURL == nil, "Unidentified file access errors do not send users to an unrelated settings page")
    let legacyOutcome = Data("{\"originalPath\":\"/old/app\",\"error\":\"old error\"}".utf8)
    try check(
        try JSONDecoder().decode(RemovalOutcome.self, from: legacyOutcome).failure == nil,
        "Old removal history remains readable without structured errors")
    let unusualPath = URL(fileURLWithPath: "/tmp/Quotes \" and $(commands) ' 日本語.app")
    let event = FinderTrash.request(for: unusualPath)
    try check(
        event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.atIndex(1)?.stringValue == unusualPath.path,
        "Finder paths are passed as data, including quotes and shell characters")
    let scriptCompiles = try finishAsync {
        await MainActor.run { () -> Bool in
            var error: NSDictionary?
            return NSAppleScript(source: FinderTrash.source)?.compileAndReturnError(&error) == true && error == nil
        }
    }
    try check(scriptCompiles, "The Finder handler compiles without executing any file operation")
    for reply: String? in [nil, ""] {
        do {
            _ = try FinderTrash.destination(reply, original: prefs)
            throw StudioError("An empty reply was accepted")
        } catch {
            try check(
                RemovalFailure(error, url: prefs, kind: .preferences).recovery == .cancelled
                    && fm.fileExists(atPath: prefs.path),
                "Finder's missing result after cancellation preserves files and reports cancellation")
        }
    }
    var unknownTrashOutcome: Error?
    do { _ = try FinderTrash.destination(nil, original: root.appendingPathComponent("Missing item")) } catch {
        unknownTrashOutcome = error
    }
    try check(
        unknownTrashOutcome.map { RemovalFailure($0, url: prefs, kind: .preferences).recovery == .other } == true,
        "An absent source without a Trash result is rejected without misreporting cancellation")

    let remaining = Set(finalPlan.candidates.filter(\.selectedByDefault).map(\.id))
    let replacement = try makeFixtureApplication(applications, name: app.name, bundleID: app.bundleID)
    try rejects("Reinstalling at the original path blocks a partial-removal retry") {
        _ = try finishAsync {
            try await ApplicationRemoval.execute(
                finalPlan, selected: remaining, scanner: scanner, running: { _ in false }, recycle: safeRecycler,
                previous: receipt.items)
        }
    }
    try fm.removeItem(at: replacement.url)
    let otherCopy = try makeFixtureApplication(applications, name: "New Paper Copy", bundleID: app.bundleID)
    try rejects("A newly installed copy protects related data during retry") {
        _ = try finishAsync {
            try await ApplicationRemoval.execute(
                finalPlan, selected: remaining, scanner: scanner, running: { _ in false }, recycle: safeRecycler,
                previous: receipt.items)
        }
    }
    try fm.removeItem(at: otherCopy.url)
    let retried = try finishAsync {
        try await ApplicationRemoval.execute(
            finalPlan, selected: remaining, scanner: scanner, running: { _ in false }, recycle: safeRecycler,
            previous: receipt.items)
    }
    try check(
        !retried.hasFailures && retried.items.count == receipt.items.count && !fm.fileExists(atPath: prefs.path),
        "Retry after partial success moves only the remaining selected files")
    try check(
        retried.items.first?.trashPath == receipt.items.first?.trashPath && fm.fileExists(atPath: support.path),
        "Retry preserves completed destinations and leaves unselected user files intact")

    let retryApp = try makeFixtureApplication(applications, name: "Access Retry", bundleID: "org.example.retry")
    let retryPrefs = library.appendingPathComponent("Preferences/" + retryApp.bundleID + ".plist")
    try file(retryPrefs)
    let retryPlan = try scanner.scan(retryApp)
    let retrySelection = Set(retryPlan.candidates.map(\.id))
    let finderDenied = try finishAsync {
        try await ApplicationRemoval.execute(
            retryPlan, selected: retrySelection, scanner: scanner, running: { _ in false },
            recycle: { _ in throw denied },
            finderRecycle: { _ in throw NSError(domain: NSOSStatusErrorDomain, code: -1743) })
    }
    try check(
        finderDenied.items.count == 1 && fm.fileExists(atPath: retryApp.path) && fm.fileExists(atPath: retryPrefs.path)
            && finderDenied.items.first?.failure?.recovery == .automation,
        "Permission failure automatically requests Finder access; refusal preserves the app and its data")
    let cancelled = try finishAsync {
        try await ApplicationRemoval.execute(
            retryPlan, selected: retrySelection, scanner: scanner, running: { _ in false },
            recycle: { _ in throw denied },
            finderRecycle: { _ in throw NSError(domain: NSOSStatusErrorDomain, code: -128) })
    }
    try check(
        cancelled.items.count == 1 && cancelled.items[0].failure?.recovery == .cancelled
            && fm.fileExists(atPath: retryPrefs.path),
        "Cancelling Finder authorization stops before touching related files")
    let recovered = try finishAsync {
        try await ApplicationRemoval.execute(
            retryPlan, selected: retrySelection, scanner: scanner, running: { _ in false },
            recycle: { _ in throw denied }, previous: finderDenied.items, usingFinder: true, finderRecycle: safeRecycler
        )
    }
    try check(
        !recovered.hasFailures && recovered.items.count == 2 && recovered.items.first?.originalPath == retryApp.path,
        "An explicit Finder retry handles app and related-file access failures in order")

    let automaticApp = try makeFixtureApplication(
        applications, name: "Automatic Approval", bundleID: "org.example.automatic-approval")
    let automaticPrefs = library.appendingPathComponent("Preferences/" + automaticApp.bundleID + ".plist")
    try file(automaticPrefs)
    let automaticPlan = try scanner.scan(automaticApp)
    let automaticSelection = Set(automaticPlan.candidates.map(\.id))
    let automatic = try finishAsync {
        try await ApplicationRemoval.execute(
            automaticPlan, selected: automaticSelection, scanner: scanner, running: { _ in false },
            recycle: { _ in throw denied }, finderRecycle: safeRecycler)
    }
    try check(
        !automatic.hasFailures && automatic.items.count == 2 && automatic.items.first?.originalPath == automaticApp.path
            && !fm.fileExists(atPath: automaticPrefs.path),
        "One confirmed removal handles app and related-file permissions automatically, in app-first order")

    let interruptedApp = try makeFixtureApplication(
        applications, name: "Interrupted Approval", bundleID: "org.example.interrupted-approval")
    let interruptedPlan = try scanner.scan(interruptedApp)
    for error in [
        NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError),
        NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)),
    ] {
        let interrupted = try finishAsync {
            try await ApplicationRemoval.execute(
                interruptedPlan, selected: [interruptedApp.path], scanner: scanner, running: { _ in false },
                recycle: { _ in throw error }, finderRecycle: safeRecycler)
        }
        try check(
            interrupted.hasFailures && fm.fileExists(atPath: interruptedApp.path)
                && interrupted.items.first?.failure?.code == error.code,
            "Cancellation and non-permission failures never invoke Finder automatically")
    }
    let changedDuringFailure = try finishAsync {
        try await ApplicationRemoval.execute(
            interruptedPlan, selected: [interruptedApp.path], scanner: scanner, running: { _ in false },
            recycle: { _ in
                _ = try makeFixtureApplication(
                    applications, name: interruptedApp.name, bundleID: interruptedApp.bundleID, version: "2.0")
                throw denied
            }, finderRecycle: safeRecycler)
    }
    try check(
        changedDuringFailure.hasFailures && fm.fileExists(atPath: interruptedApp.path)
            && changedDuringFailure.items.first?.failure?.recovery == .other,
        "An app updated during native failure is revalidated and never passed to Finder")

    let vendor = applications.appendingPathComponent("Protected Vendor")
    let adminApp = try makeFixtureApplication(vendor, name: "Admin Probe", bundleID: "org.example.admin-probe")
    let adminPlan = try scanner.scan(adminApp)
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: vendor.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vendor.path) }
    try check(FinderTrash.needsAuthorization(adminApp.url), "An unwritable vendor folder is detected before deletion")
    let adminFailure = RemovalFailure(denied, url: adminApp.url, kind: .application)
    try check(
        adminFailure.recovery == .administrator && adminFailure.settingsURL == nil,
        "A protected vendor directory is not misreported as an App Management switch")
    let adminReceipt = try finishAsync {
        try await ApplicationRemoval.execute(
            adminPlan, selected: [adminApp.path], scanner: scanner, running: { _ in false },
            recycle: { _ in throw StudioError("Unexpected native deletion") },
            finderRecycle: { url in
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vendor.path)
                return try await safeRecycler(url)
            })
    }
    try check(
        !adminReceipt.hasFailures && !fm.fileExists(atPath: adminApp.path),
        "Protected folders route to Finder authorization on the first confirmed removal")

    // Integration: native Trash API, only for a newly created disposable probe.
    let probe = root.appendingPathComponent("Studio-Trash-Probe-" + UUID().uuidString + ".txt")
    try file(probe)
    let trashedProbe = try finishAsync { try await ApplicationRemoval.recycle(probe) }
    try check(
        !fm.fileExists(atPath: probe.path) && fm.fileExists(atPath: trashedProbe.path),
        "Native macOS recycling returns the actual Trash destination")
    guard trashedProbe.lastPathComponent.hasPrefix("Studio-Trash-Probe-") else {
        throw StudioError("Unexpected Trash destination")
    }
    try fm.removeItem(at: trashedProbe)
    let nativeApp = try makeFixtureApplication(
        applications, name: "Studio-Trash-App-Probe-" + UUID().uuidString, bundleID: "org.example.trash-probe")
    let nativePlan = try scanner.scan(nativeApp)
    let nativeReceipt = try finishAsync {
        try await ApplicationRemoval.execute(
            nativePlan, selected: [nativeApp.path], scanner: scanner, running: { _ in false })
    }
    try check(
        nativeReceipt.items.first?.trashPath != nil && !fm.fileExists(atPath: nativeApp.path),
        "Native recycling also removes an application bundle")
    if let nativeTrash = nativeReceipt.items.first?.trashPath,
        URL(fileURLWithPath: nativeTrash).lastPathComponent.hasPrefix("Studio-Trash-App-Probe-")
    {
        try fm.removeItem(at: URL(fileURLWithPath: nativeTrash))
    }

    // Exercise a real catalog change without changing the user's Launchpad database.
    let database = root.appendingPathComponent("launchpad.sqlite")
    try Database(TestFixture.source().path).snapshot(to: database)
    let model = StudioModel(
        dataRoot: root.appendingPathComponent("Model"), locateSource: { database }, removalScanner: scanner)
    let discoveryModel = StudioModel(
        dataRoot: root.appendingPathComponent("Discovery Save Failure"), locateSource: { database },
        removalScanner: scanner)
    let discoveryFile = discoveryModel.dataRoot.appendingPathComponent("app-discovery.json")
    try fm.createDirectory(at: discoveryFile, withIntermediateDirectories: true)
    discoveryModel.receiveApplications([nested])
    try check(
        discoveryModel.hasUnsavedChanges && discoveryModel.inventoryIssue != nil,
        "A failed discovery save remains pending instead of being forgotten")
    discoveryModel.receiveApplications([nested])
    try check(
        discoveryModel.hasUnsavedChanges && discoveryModel.inventoryIssue != nil,
        "An unchanged inventory cannot hide a repeated discovery save failure")
    try fm.removeItem(at: discoveryFile)
    discoveryModel.receiveApplications([nested])
    let savedDiscovery = try JSONDecoder().decode(AppDiscoveryState.self, from: Data(contentsOf: discoveryFile))
    try check(
        !discoveryModel.hasUnsavedChanges && discoveryModel.inventoryIssue == nil
            && savedDiscovery.known.contains(nested.bundleID),
        "The next stable inventory retries and persists a previously failed save")
    let nestedCache = library.appendingPathComponent("Caches/" + nested.bundleID)
    try file(nestedCache.appendingPathComponent("cache.bin"))
    model.prepareRemoval(nested)
    var scanDeadline = Date().addingTimeInterval(10)
    while model.removalScanning && Date() < scanDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    try check(
        model.removalPlan != nil && model.removalSelection.contains(nestedCache.path),
        "Removal preparation offers the matching cache")
    model.removalSelection.remove(nestedCache.path)
    model.scanRemoval()
    scanDeadline = Date().addingTimeInterval(10)
    while model.removalScanning && Date() < scanDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    try check(
        model.removalPlan != nil && !model.removalSelection.contains(nestedCache.path)
            && model.removalSelection.contains(nested.path), "Rescanning preserves the user's file selection")
    model.closeRemoval()
    let partialApp = try makeFixtureApplication(
        applications, name: "Partial Rescan", bundleID: "org.example.partial-rescan")
    let partialPrefs = library.appendingPathComponent("Preferences/" + partialApp.bundleID + ".plist")
    try file(partialPrefs)
    let partialPlan = try scanner.scan(partialApp)
    let partialSelection = Set(partialPlan.candidates.map(\.id))
    let partialReceipt = try finishAsync {
        try await ApplicationRemoval.execute(
            partialPlan, selected: partialSelection, scanner: scanner, running: { _ in false },
            recycle: { url in
                if url == partialPrefs { throw StudioError("Synthetic failure") }
                return try await safeRecycler(url)
            })
    }
    try file(partialPrefs, text: "Changed while waiting to retry")
    model.removalTarget = partialApp
    model.removalPlan = partialPlan
    model.removalReceipt = partialReceipt
    model.removalSelection = partialSelection
    model.scanRemoval()
    scanDeadline = Date().addingTimeInterval(10)
    while model.removalScanning && Date() < scanDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    try check(
        model.removalError == nil && model.removalCompleted.count == 1
            && model.removalCompleted.first?.trashPath == partialReceipt.items.first?.trashPath,
        "Rescanning after partial removal retains the original app's Trash receipt")
    guard let rescanned = model.removalPlan else { throw StudioError("Missing partial-removal rescan") }
    try check(
        rescanned.candidates.first { $0.id == partialPrefs.path }?.stamp == (try FileStamp(partialPrefs))
            && model.removalSelection.contains(partialPrefs.path),
        "A changed remaining file can be reviewed again after its app was removed")
    let finished = try finishAsync {
        try await ApplicationRemoval.execute(
            rescanned, selected: model.removalSelection, scanner: scanner, running: { _ in false },
            recycle: safeRecycler, previous: model.removalCompleted)
    }
    try check(
        !finished.hasFailures && finished.items.count == 2
            && finished.items.first?.trashPath == partialReceipt.items.first?.trashPath,
        "Confirming the rescanned remainder never retries or loses the already removed app")
    _ = try makeFixtureApplication(applications, name: partialApp.name, bundleID: partialApp.bundleID)
    try rejects("Restoring or reinstalling the app blocks a stale partial-removal rescan") {
        _ = try ApplicationRemoval.rescan(rescanned, previous: finished.items, scanner: scanner)
    }
    model.closeRemoval()
    guard let folder = model.folders.first else { throw StudioError("Missing fixture folder") }
    model.rename(folder.id, to: "Keep this arrangement")
    let arranged = model.layout
    model.selectedTile = folder.id
    model.selectedApp = folder.appIDs.first
    let beforeIDs = Set(model.apps.map(\.id))
    let db = try Database(database.path, writable: true)
    try makeFixturePage(db, id: 900002)
    try db.execute("INSERT INTO items VALUES (900000,'NEW-LIFECYCLE-APP',0,4,900002,0)")
    try db.execute("INSERT INTO apps VALUES (900000,'Pencil','org.example.pencil',NULL,3,0,NULL)")
    model.receiveApplications([nested])
    try check(
        model.layout.tiles.first { $0.id == folder.id }?.name == "Keep this arrangement"
            && model.layout.appIDs.contains(900000), "New installations rebase onto the edited preview")
    try check(
        Set(model.layout.appIDs) == beforeIDs.union([900000]),
        "A new installation appears once without losing existing apps")
    try check(
        model.selectedApp == folder.appIDs.first && model.selectedTile == folder.id,
        "A catalog refresh retains the selected app and folder")
    model.undo()
    try check(
        model.layout.appIDs.contains(900000)
            && model.layout.tiles.first { $0.id == folder.id }?.name != "Keep this arrangement",
        "Undo remains usable after a catalog addition")
    model.redo()
    try check(
        model.layout.tiles.first { $0.id == folder.id }?.name == "Keep this arrangement",
        "Redo preserves the new catalog and the user's edits")
    model.discovery.pending = [nested.bundleID]
    model.reviewNewApplications()
    try check(
        model.selectedTab == "preview" && model.inspectedApp?.id == 900000 && model.tile?.isFolder == false,
        "The new-app toast selects the app in the existing preview")
    model.search = "Pencil"
    try check(
        model.previewTiles.flatMap(\.appIDs) == [900000], "Search finds a standalone app inside the existing grid")
    model.search = "  Pencil\n"
    try check(
        model.previewTiles.flatMap(\.appIDs) == [900000], "Pasted search terms ignore leading and trailing whitespace")
    model.search = " \n "
    try check(
        model.previewTiles == model.layout.pages[model.pageIndex].tiles,
        "Whitespace-only searches show the current page instead of an empty result")
    model.pageIndex = 0
    model.selectTile("app-900000")
    model.search = ""
    try check(
        model.previewTiles.contains { $0.appIDs.contains(900000) } && model.inspectedApp?.id == 900000,
        "Clearing a search retains the selected app's page")
    model.search = "no-such-installed-app"
    try check(model.previewTiles.isEmpty, "A search without a match has no grid results")
    model.search = ""
    model.selectedApp = nil
    try check(model.inspectedApp?.id == 900000, "A standalone app shows app details without a nested selection")
    model.selectedApp = arranged.appIDs[0]
    try check(model.inspectedApp?.id == 900000, "A stale folder selection cannot override a standalone app inspector")
    model.selectedTile = folder.id
    model.selectedApp = 900000
    try check(model.inspectedApp == nil, "A folder does not display an app selected in another tile")
    model.selectedApp = folder.appIDs.first
    try check(model.inspectedApp?.id == folder.appIDs.first, "Selecting a folder member shows that app's details")
    model.reviewNewApplications()
    try check(
        model.removalApp(for: 900000)?.bundleID == nested.bundleID,
        "A newly registered app can be removed before its bookmark is available")
    model.moveApps([900000], to: folder.id)
    try check(
        arranged.appIDs.allSatisfy { model.layout.location($0) == arranged.location($0) },
        "Moving a new app keeps the existing arrangement")
    try check(
        model.discovery.pending.isEmpty
            && model.layout.tiles.first { $0.id == folder.id }?.appIDs.contains(900000) == true,
        "The normal folder menu clears the new-app reminder and shows the chosen destination")
    model.search = "org.example.pencil"
    try check(
        model.previewTiles.map(\.id) == [folder.id] && model.matchesSearch(900000),
        "Search finds the containing folder without opening an app-list screen")
    model.search = ""
    model.discovery.pending = [nested.bundleID]
    try check(model.newApplications.isEmpty, "An app already arranged in a folder is not reported as unclassified")
    try db.execute("DELETE FROM items WHERE rowid=900000")
    model.reconcileLaunchpadCatalog()
    try check(
        !model.layout.appIDs.contains(900000) && Set(model.layout.appIDs) == beforeIDs,
        "Uninstallation removes only the missing catalog entry")
    model.undo()
    try check(!model.layout.appIDs.contains(900000), "Undo after uninstall cannot resurrect a deleted app record")
    model.receiveApplications([nested, partialApp])
    model.discovery.pending = [partialApp.bundleID]
    model.newAppToast = true
    model.reviewNewApplications()
    try check(
        model.waitingForNewAppRegistration && model.newAppToast,
        "Reviewing a new app before Launchpad registration keeps the request pending")
    try db.execute("INSERT INTO items VALUES (900001,'DELAYED-REGISTRATION',0,4,900002,0)")
    try db.execute("INSERT INTO apps VALUES (900001,'Partial Rescan','org.example.partial-rescan',NULL,3,0,NULL)")
    model.receiveApplications([nested, partialApp])
    try check(
        !model.waitingForNewAppRegistration && model.inspectedApp?.id == 900001 && !model.newAppToast,
        "A pending new-app review opens the app once Launchpad registers it")
    let delegate = AppDelegate()
    delegate.model = model
    try check(
        delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
        "Closing the window quits by default")
    delegate.window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false
    )
    let reviewItem = NSMenuItem(title: "", action: #selector(AppDelegate.reviewNewApps), keyEquivalent: "")
    model.newAppToast = false
    model.selectedTab = "backups"
    try check(
        delegate.validateMenuItem(reviewItem)
            && reviewItem.title == L("Review New Apps ({0})…", model.newApplications.count),
        "New apps remain discoverable from the menu after the toast is gone")
    model.busy = true
    delegate.reviewNewApps()
    try check(
        !delegate.validateMenuItem(reviewItem) && model.selectedTab == "backups",
        "The new-app menu cannot interrupt an ongoing operation")
    model.busy = false
    delegate.reviewNewApps()
    try check(
        model.selectedTab == "preview" && model.inspectedApp?.id == 900001,
        "The menu returns to the pending app in the existing layout")
    model.discovery.pending = []
    try check(!delegate.validateMenuItem(reviewItem), "The new-app menu is disabled when nothing needs review")

    // Integration: recursive filesystem watching and stable-scan delivery.
    try check(
        try ApplicationInventory.scan(roots: [applications]).contains(where: { $0.bundleID == nested.bundleID }),
        "A dangling app alias cannot hide applications in a later subfolder")
    var delivered: [InstalledApplication]?
    var monitorError: Error?
    let monitor = ApplicationMonitor(roots: [applications]) { result in
        do { delivered = try result.get() } catch { monitorError = error }
    }
    defer { monitor.stop() }
    monitor.start()
    var deadline = Date().addingTimeInterval(15)
    while delivered == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    if let monitorError { throw StudioError("Initial inventory failed: " + monitorError.localizedDescription) }
    if delivered?.contains(where: { $0.bundleID == nested.bundleID }) != true {
        throw StudioError(
            "Initial inventory mismatch: \(String(describing: delivered?.map(\.bundleID))); expected \(nested.bundleID)"
        )
    }
    try check(
        delivered?.contains(where: { $0.bundleID == nested.bundleID }) == true,
        "The monitor delivers its stable initial scan")
    let watched = try makeFixtureApplication(
        applications.appendingPathComponent("Utilities"), name: "Watched", bundleID: "org.example.watched")
    deadline = Date().addingTimeInterval(20)
    while delivered?.contains(where: { $0.bundleID == watched.bundleID }) != true && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    monitor.stop()
    try check(
        delivered?.contains(where: { $0.bundleID == watched.bundleID }) == true,
        "A nested app installation triggers recursive filesystem detection")
    print("SUCCESS: \(checks) app-management checks passed. Removal used disposable fixtures only.")
}
