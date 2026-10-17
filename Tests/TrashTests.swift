import AppKit
import Carbon

private final class TrashTestResult: @unchecked Sendable {
    let lock = NSLock()
    private var result: Result<TrashEmptying.Outcome, Error>?
    func put(_ value: Result<TrashEmptying.Outcome, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }
    func get() -> Result<TrashEmptying.Outcome, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
private final class EditingTestView: NSTextView {
    let editingUndo = UndoManager()
    override var undoManager: UndoManager? { editingUndo }
}

func runTrashTests() throws {
    _ = NSApplication.shared
    defer { L10n.testCode = nil }
    L10n.testCode = "en"
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw StudioError(message) }
        checks += 1
        print("PASS \(checks): \(message)")
    }
    // Every test provides a fake transport. No test sends an event to Finder.
    func run(_ confirmed: Bool, _ send: @escaping TrashEmptying.Send) throws -> TrashEmptying.Outcome {
        let result = TrashTestResult()
        Task.detached {
            do { result.put(.success(try await TrashEmptying.run(confirmed: confirmed, send: send))) } catch {
                result.put(.failure(error))
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while result.get() == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard let result = result.get() else { throw StudioError("Trash test timed out") }
        return try result.get()
    }
    var calls = 0
    let cancelled = try run(false) { _ in
        calls += 1
        throw StudioError("Unconfirmed deletion must never dispatch")
    }
    try check(cancelled == .cancelled && calls == 0, "Cancelling confirmation never contacts Finder")
    var sentOnMain = true
    var target: String?
    let requested = try run(true) { event in
        calls += 1
        sentOnMain = Thread.isMainThread
        let address = event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))
        target = address.flatMap { String(data: $0.data, encoding: .utf8) }
        guard event.eventClass == 0x666e_6472, event.eventID == 0x656d_7074 else {
            throw StudioError("Wrong Finder command")
        }
        return NSAppleEventDescriptor.record()
    }
    try check(requested == .requested && calls == 1, "Confirmed request sends exactly one native Finder empty command")
    try check(!sentOnMain, "Finder authorization and replies cannot block the main event loop")
    try check(target == "com.apple.finder", "Empty command can target only Finder")
    let finderCancel = try run(true) { _ in
        let reply = NSAppleEventDescriptor.record()
        reply.setParam(NSAppleEventDescriptor(int32: -128), forKeyword: AEKeyword(keyErrorNumber))
        return reply
    }
    try check(finderCancel == .cancelled, "Finder's cancel reply is treated as cancellation, not success")
    let cocoaCancel = try run(true) { _ in throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
    try check(cocoaCancel == .cancelled, "Native user cancellation does not show an error")
    for code in [-1743, -1712, -45] {
        var attempts = 0
        do {
            _ = try run(true) { _ in
                attempts += 1
                let reply = NSAppleEventDescriptor.record()
                reply.setParam(NSAppleEventDescriptor(int32: Int32(code)), forKeyword: AEKeyword(keyErrorNumber))
                reply.setParam(
                    NSAppleEventDescriptor(string: "Finder test error"), forKeyword: AEKeyword(keyErrorString))
                return reply
            }
            throw StudioError("Finder error was silently accepted")
        } catch {
            let error = error as NSError
            try check(
                error.domain == NSOSStatusErrorDomain && error.code == code && attempts == 1,
                "Finder error \(code) is preserved without retrying permanent deletion")
            if code == -1743 {
                try check(
                    TrashEmptying.needsFinderPermission(error),
                    "Automation denial provides a Finder permission recovery path")
            }
            if code == -1712 {
                try check(
                    TrashEmptying.failureMessage(error).contains("may still be in progress"),
                    "Timeout does not claim that deletion stopped or completed")
            }
        }
    }
    do {
        _ = try run(true) { _ in throw NSError(domain: NSOSStatusErrorDomain, code: -1743) }
        throw StudioError("Transport failure was accepted")
    } catch {
        try check(TrashEmptying.needsFinderPermission(error), "Transport-level permission errors remain actionable")
    }
    let source = try TestFixture.source()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("StudioTrashTests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let delegate = AppDelegate()
    delegate.model = StudioModel(dataRoot: root, locateSource: { source })
    let updateDomain = "org.example.studio-trash-update-test." + UUID().uuidString
    let updateDefaults = UserDefaults(suiteName: updateDomain)!
    defer { updateDefaults.removePersistentDomain(forName: updateDomain) }
    delegate.updates = UpdateChecker(defaults: updateDefaults, loader: { $0(.success(nil)) })
    delegate.window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false
    )
    let item = NSMenuItem(title: "", action: #selector(AppDelegate.emptyTrash), keyEquivalent: "")
    let updateItem = NSMenuItem(title: "", action: #selector(AppDelegate.checkForUpdates), keyEquivalent: "")
    try check(delegate.validateMenuItem(item), "Trash menu is available when the app is idle")
    try check(delegate.validateMenuItem(updateItem), "Update checks are available when the app is idle")
    delegate.model.busy = true
    try check(
        !delegate.validateMenuItem(item) && !delegate.allowClose(),
        "Deletion and apply operations block emptying and quitting")
    try check(!delegate.validateMenuItem(updateItem), "Update actions cannot interrupt an ongoing deletion or apply")
    delegate.model.busy = false
    let sheet = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false
    )
    delegate.window.beginSheet(sheet)
    try check(
        !delegate.validateMenuItem(item), "An existing app deletion or confirmation sheet blocks a second Trash action")
    try check(!delegate.validateMenuItem(updateItem), "An open confirmation sheet blocks update actions")
    delegate.window.endSheet(sheet)
    let folder = delegate.model.folders[0]
    delegate.model.rename(folder.id, to: "Editing regression")
    let editedLayout = delegate.model.layout
    let editor = EditingTestView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    editor.isFieldEditor = true
    editor.isEditable = true
    editor.allowsUndo = true
    delegate.window.contentView = editor
    delegate.window.makeFirstResponder(editor)
    let undoItem = NSMenuItem(title: "", action: #selector(AppDelegate.undoEdit), keyEquivalent: "")
    let redoItem = NSMenuItem(title: "", action: #selector(AppDelegate.redoEdit), keyEquivalent: "")
    try check(delegate.textEditor === editor, "Text editing owns the undo context while the field is focused")
    delegate.undoEdit()
    try check(
        delegate.model.layout == editedLayout && !delegate.validateMenuItem(undoItem),
        "Undo in an unchanged text field cannot undo the Launchpad layout")
    editor.string = "typed text"
    editor.editingUndo.registerUndo(withTarget: editor) { $0.string = "previous text" }
    delegate.undoEdit()
    try check(
        editor.string == "previous text" && delegate.model.layout == editedLayout,
        "Undo changes the focused text without touching the app arrangement")
    editor.editingUndo.removeAllActions()
    delegate.model.undo()
    let undoneLayout = delegate.model.layout
    delegate.redoEdit()
    try check(
        delegate.model.layout == undoneLayout && !delegate.validateMenuItem(redoItem),
        "Redo in a text field cannot unexpectedly redo a layout edit")
    delegate.window.makeFirstResponder(nil)
    delegate.redoEdit()
    try check(delegate.model.layout == editedLayout, "Layout redo is available again after leaving the text field")
    delegate.window.beginSheet(sheet)
    delegate.undoEdit()
    try check(
        delegate.model.layout == editedLayout && !delegate.validateMenuItem(undoItem),
        "Undo cannot change the background layout while a sheet is open")
    delegate.window.endSheet(sheet)
    delegate.undoEdit()
    let beforeSheetRedo = delegate.model.layout
    delegate.window.beginSheet(sheet)
    delegate.redoEdit()
    try check(
        delegate.model.layout == beforeSheetRedo && !delegate.validateMenuItem(redoItem),
        "Redo cannot change the background layout while a sheet is open")
    delegate.window.endSheet(sheet)
    delegate.redoEdit()
    try check(delegate.model.layout == editedLayout, "Closing a sheet restores normal layout keyboard shortcuts")
    let settingsItem = NSMenuItem(title: "", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
    delegate.settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 660),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    delegate.model.settingsWindowActive = true
    delegate.undoEdit()
    try check(delegate.model.layout == editedLayout && !delegate.validateMenuItem(undoItem),
        "Undo in Settings cannot modify the background Launchpad layout")
    try check(delegate.validateMenuItem(settingsItem) && delegate.windowShouldClose(delegate.settingsWindow!),
        "Settings can reopen or close independently while idle")
    delegate.settingsWindow!.beginSheet(sheet)
    try check(!delegate.validateMenuItem(settingsItem) && !delegate.validateMenuItem(item)
        && !delegate.validateMenuItem(updateItem) && !delegate.allowClose(),
        "A Settings sheet blocks competing settings, Trash, update and quit actions")
    delegate.settingsWindow!.endSheet(sheet)
    delegate.model.busy = true
    try check(!delegate.validateMenuItem(settingsItem) && !delegate.windowShouldClose(delegate.settingsWindow!),
        "A running operation blocks Settings actions and closing")
    delegate.model.busy = false
    delegate.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: delegate.window))
    try check(!delegate.model.settingsWindowActive && delegate.validateMenuItem(undoItem),
        "Returning to the main window restores its layout undo context")
    for code in ["en", "ko", "ja", "zh-Hans"] {
        L10n.testCode = code
        delegate.setupMenu()
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        let settings = appMenu?.items.filter { $0.action == #selector(AppDelegate.showSettings) } ?? []
        try check(settings.count == 1 && settings[0].title == L("Settings…") && settings[0].keyEquivalent == ",",
            "\(code): Settings is available once in the app menu with Command-comma")
    }
    delegate.settingsWindow = nil
    for code in ["en", "ko", "ja", "zh-Hans"] {
        L10n.testCode = code
        let alert = TrashEmptying.confirmation()
        try check(
            alert.buttons.count == 2 && alert.buttons[0].title == L("Cancel") && alert.buttons[0].keyEquivalent == "\r"
                && alert.buttons[1].keyEquivalent.isEmpty && alert.buttons[1].hasDestructiveAction,
            "\(code): confirmation defaults to Cancel, with a separate destructive action")
        try check(
            !alert.informativeText.isEmpty && (code == "en" || alert.messageText != "Empty the Trash?"),
            "\(code): permanent-deletion warning is localized")
        delegate.setupMenu()
        let entries = NSApp.mainMenu?.items.first?.submenu?.items ?? []
        try check(
            entries.contains {
                $0.title == L("Check for Updates…") && $0.action == #selector(AppDelegate.checkForUpdates)
            },
            "\(code): the native update menu is localized")
        try check(
            entries.contains {
                $0.title == L("Empty Trash…") && $0.action == #selector(AppDelegate.emptyTrash)
                    && $0.keyEquivalent.isEmpty
            },
            "\(code): the app menu exposes Trash emptying without an accidental keyboard shortcut")
        try check(
            entries.contains {
                $0.title == L("Review New Apps ({0})…", delegate.model.newApplications.count)
                    && $0.action == #selector(AppDelegate.reviewNewApps)
            },
            "\(code): pending-app navigation is localized in the native menu")
    }
    print("SUCCESS: \(checks) trash checks passed. No Finder events were sent and no real Trash was emptied.")
}
