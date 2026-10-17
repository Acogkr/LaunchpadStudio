import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var settingsWindow: NSWindow?
    var model: StudioModel!
    var updates: UpdateChecker!
    private var busyObservation: AnyCancellable?
    private var sessionLock: SessionLock?
    func applicationDidFinishLaunching(_ notification: Notification) {
        var sessionRoot = StudioModel.defaultDataRoot
        #if STUDIO_TESTING
            let previewRoot = (Bundle.main.object(forInfoDictionaryKey: "StudioPreviewRoot") as? String).map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath()
            }
            if let previewRoot { sessionRoot = previewRoot.appendingPathComponent("Data") }
        #endif
        do {
            guard let lock = try SessionLock(directory: sessionRoot) else {
                NSRunningApplication.runningApplications(withBundleIdentifier: "local.launchpadstudio.app")
                    .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?.activate(options: [
                        .activateAllWindows
                    ])
                NSApp.terminate(nil)
                return
            }
            sessionLock = lock
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Unable to Complete")
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = studioIcon()
        #if STUDIO_TESTING
            if let previewRoot {
                do { model = try makeManagementPreview(previewRoot) } catch {
                    fputs("Preview failed: \(error.localizedDescription)\n", stderr)
                    NSApp.terminate(nil)
                    return
                }
            } else {
                model = StudioModel()
            }
        #else
            model = StudioModel()
        #endif
        #if STUDIO_TESTING
            updates = previewRoot != nil ? makeUpdatePreview() : UpdateChecker()
        #else
            updates = UpdateChecker()
        #endif
        let view = StudioView().environmentObject(model).environmentObject(updates)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 870),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        busyObservation = model.$busy.sink { [weak self] busy in
            self?.window.standardWindowButton(.closeButton)?.isEnabled = !busy
        }
        window.title = "Launchpad Studio"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView = NSHostingView(rootView: view)
        (window.fieldEditor(true, for: nil) as? NSTextView)?.allowsUndo = true
        window.minSize = NSSize(width: 1150, height: 760)
        window.setFrameAutosaveName("LaunchpadStudioWindow")
        window.center()
        setupMenu()
        NotificationCenter.default.addObserver(
            self, selector: #selector(languageDidChange), name: Localization.changed, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemLocaleDidChange), name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.startApplicationMonitor()
        updates.start()
    }
    @objc func systemLocaleDidChange() { Localization.shared.refreshSystemLanguage() }
    @objc func languageDidChange() {
        setupMenu()
        settingsWindow?.title = L("Settings")
    }
    @objc func showSettings() {
        guard canHandleEditMenu else { return }
        if settingsWindow == nil {
            let height = min(660, ((window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 760) - 100)
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: height),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = L("Settings")
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: SettingsView().environmentObject(model).environmentObject(updates))
            panel.center()
            settingsWindow = panel
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow { model?.settingsWindowActive = true }
        else if (notification.object as? NSWindow) === window { model?.settingsWindowActive = false }
        // Keep the presentation context while a child sheet or file dialog becomes key.
    }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow { model?.settingsWindowActive = false }
    }
    func focusMainWindow() {
        settingsWindow?.orderOut(nil)
        model?.settingsWindowActive = false
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }
    func setupMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("About Launchpad Studio"), action: #selector(about), keyEquivalent: "").target =
            self
        appMenu.addItem(withTitle: updates.actionTitle, action: #selector(checkForUpdates), keyEquivalent: "").target =
            self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L("Review New Apps ({0})…", model.newApplications.count), action: #selector(reviewNewApps),
            keyEquivalent: ""
        ).target = self
        appMenu.addItem(withTitle: L("Recent Deletions…"), action: #selector(recentDeletions), keyEquivalent: "")
            .target = self
        appMenu.addItem(withTitle: L("Find Leftover Files…"), action: #selector(findLeftovers), keyEquivalent: "")
            .target = self
        appMenu.addItem(withTitle: L("Empty Trash…"), action: #selector(emptyTrash), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L("Hide Launchpad Studio"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(
            withTitle: L("Quit Launchpad Studio"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem(title: L("Edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(withTitle: L("Undo"), action: #selector(undoEdit), keyEquivalent: "z").target = self
        let redo = editMenu.addItem(withTitle: L("Redo"), action: #selector(redoEdit), keyEquivalent: "z")
        redo.target = self
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let windowItem = NSMenuItem(title: L("Window"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(
            withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }
    @objc func recentDeletions() {
        guard canEmptyTrash else { return }
        focusMainWindow()
        model.cleanupPanel = .history
    }
    @objc func reviewNewApps() {
        guard canEmptyTrash, !model.newApplications.isEmpty else { return }
        focusMainWindow()
        model.reviewNewApplications()
    }
    @objc func findLeftovers() {
        guard canEmptyTrash else { return }
        focusMainWindow()
        model.cleanupPanel = .leftovers
    }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Launchpad Studio", .applicationVersion: AppVersion.current,
            .credits: NSAttributedString(string: L("macOS Launchpad layout editor")),
        ])
    }
    @objc func checkForUpdates() {
        guard canHandleEditMenu else { return }
        if updates.availableRelease == nil {
            showSettings()
            updates.check(manual: true)
        } else if !updates.openRelease() { showSettings() }
    }
    var textEditor: NSTextView? {
        let activeWindow = model?.settingsWindowActive == true ? settingsWindow : window
        guard let editor = activeWindow?.firstResponder as? NSTextView, editor.isEditable, editor.isFieldEditor else {
            return nil
        }
        return editor
    }
    var textUndoManager: UndoManager? { textEditor?.undoManager }
    var canHandleEditMenu: Bool {
        model?.busy != true && window?.attachedSheet == nil && settingsWindow?.attachedSheet == nil && NSApp.modalWindow == nil
    }
    @objc func undoEdit() {
        guard canHandleEditMenu else { return }
        if let editor = textEditor {
            if editor.undoManager?.canUndo == true { editor.undoManager?.undo() }
        } else if model?.settingsWindowActive != true {
            model?.undo()
        }
    }
    @objc func redoEdit() {
        guard canHandleEditMenu else { return }
        if let editor = textEditor {
            if editor.undoManager?.canRedo == true { editor.undoManager?.redo() }
        } else if model?.settingsWindowActive != true {
            model?.redo()
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showSettings) { return canHandleEditMenu }
        if item.action == #selector(checkForUpdates) {
            item.title = updates.actionTitle
            return canHandleEditMenu && !updates.isChecking
        }
        if item.action == #selector(reviewNewApps) {
            item.title = L("Review New Apps ({0})…", model?.newApplications.count ?? 0)
            return canEmptyTrash && model?.newApplications.isEmpty == false
        }
        if item.action == #selector(recentDeletions) || item.action == #selector(findLeftovers) { return canEmptyTrash }
        if item.action == #selector(emptyTrash) { return canEmptyTrash }
        if item.action == #selector(undoEdit) {
            return canHandleEditMenu
                && (textEditor != nil
                    ? textUndoManager?.canUndo == true : (model?.settingsWindowActive != true && model?.canEdit == true && model?.undoStack.isEmpty == false))
        }
        if item.action == #selector(redoEdit) {
            return canHandleEditMenu
                && (textEditor != nil
                    ? textUndoManager?.canRedo == true : (model?.settingsWindowActive != true && model?.canEdit == true && model?.redoStack.isEmpty == false))
        }
        return true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        allowClose() ? .terminateNow : .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === settingsWindow { return model?.busy != true && sender.attachedSheet == nil }
        return allowClose()
    }
    func allowClose() -> Bool {
        guard model?.busy != true && settingsWindow?.attachedSheet == nil else { return false }
        guard let model, !model.retryPendingSaves() else { return true }
        let alert = NSAlert()
        alert.messageText = L("Some changes could not be saved.")
        alert.informativeText = L("Keep the app open to retry saving, or quit and discard the unsaved changes.")
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Quit Without Saving"))
        return alert.runModal() == .alertSecondButtonReturn
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        model?.launchpadMonitor?.refresh(force: true)
        model?.applicationMonitor?.refresh()
        updates?.check()
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.applicationMonitor?.stop()
        model?.launchpadMonitor?.stop()
        updates?.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
