import AppKit
import Carbon

private final class TrashConfirmationAlert: NSAlert {
    private var escapeMonitor: Any?
    override func beginSheetModal(
        for sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        // A button has one key equivalent. Keep Return on Cancel and handle
        // Escape locally for this sheet, without a global keyboard listener.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 53 else { return event }
            self.buttons.first?.performClick(nil)
            return nil
        }
        super.beginSheetModal(for: sheetWindow) { [self] response in
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
                self.escapeMonitor = nil
            }
            handler?(response)
        }
    }
    deinit { if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) } }
}

enum TrashEmptying {
    enum Outcome { case cancelled, requested }
    typealias Send = (NSAppleEventDescriptor) throws -> NSAppleEventDescriptor
    private static let queue = DispatchQueue(label: "local.launchpadstudio.empty-trash", qos: .userInitiated)

    static func request() -> NSAppleEventDescriptor {
        // Finder.sdef: the "empty" command (fndr/empt) targets the user's whole Trash.
        NSAppleEventDescriptor(
            eventClass: 0x666e_6472, eventID: 0x656d_7074,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }
    static func sendToFinder(_ request: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try request.sendEvent(options: [.waitForReply, .canInteract, .canSwitchLayer], timeout: 600)
    }
    static func validateReply(_ reply: NSAppleEventDescriptor) throws {
        let code = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
        guard code != 0 else { return }
        let message =
            reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue ?? L("Could not empty the Trash.")
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func wasCancelled(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSOSStatusErrorDomain && error.code == -128)
            || (error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError)
    }
    static func needsFinderPermission(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSOSStatusErrorDomain && error.code == -1743
    }
    static func failureMessage(_ error: Error) -> String {
        let error = error as NSError
        if needsFinderPermission(error) {
            return L("In Automation, expand Launchpad Studio and enable Finder, then retry.")
        }
        if error.domain == NSOSStatusErrorDomain && error.code == -1712 {
            return L("Finder has not replied yet. Check Finder before trying again; emptying may still be in progress.")
        }
        return error.localizedDescription
    }
    static func run(confirmed: Bool, send: @escaping Send = sendToFinder) async throws -> Outcome {
        guard confirmed else { return .cancelled }
        return try await withCheckedThrowingContinuation { continuation in
            // Keep the Apple event and its reply on this queue so a system prompt
            // or a large Trash never blocks the app's main event loop.
            queue.async {
                do {
                    try validateReply(send(request()))
                    continuation.resume(returning: .requested)
                } catch {
                    if wasCancelled(error) {
                        continuation.resume(returning: .cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    static func confirmation() -> NSAlert {
        let alert = TrashConfirmationAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Empty the Trash?")
        alert.informativeText = L(
            "All items in your Mac’s Trash will be permanently deleted, including items removed outside Launchpad Studio. This cannot be undone."
        )
        let cancel = alert.addButton(withTitle: L("Cancel"))
        cancel.keyEquivalent = "\r"
        let destructive = alert.addButton(withTitle: L("Empty Trash"))
        destructive.keyEquivalent = ""
        destructive.hasDestructiveAction = true
        return alert
    }
}

extension AppDelegate {
    var canEmptyTrash: Bool {
        guard let model, window != nil else { return false }
        return !model.busy && canHandleEditMenu
    }

    @objc func emptyTrash() {
        guard canEmptyTrash, let window else { return }
        focusMainWindow()
        TrashEmptying.confirmation().beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self, let model = self.model, !model.busy else { return }
            model.busyText = L("Requesting Finder to empty the Trash…")
            model.busy = true
            Task { @MainActor in
                let result: Result<TrashEmptying.Outcome, Error>
                do { result = .success(try await TrashEmptying.run(confirmed: true)) } catch {
                    result = .failure(error)
                }
                model.busy = false
                NSApp.activate(ignoringOtherApps: true)
                switch result {
                case .success(.requested):
                    // Finder may continue handling locked files in its own UI.
                    model.notice = L("Trash emptying requested in Finder.")
                case .success(.cancelled): break
                case .failure(let error): self.presentTrashFailure(error)
                }
            }
        }
    }
    func presentTrashFailure(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Could not empty the Trash.")
        alert.informativeText = TrashEmptying.failureMessage(error)
        let needsPermission = TrashEmptying.needsFinderPermission(error)
        alert.addButton(withTitle: needsPermission ? L("Cancel") : L("OK"))
        if needsPermission { alert.addButton(withTitle: L("Open Finder Permissions…")) }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard needsPermission, response == .alertSecondButtonReturn,
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            else { return }
            if !NSWorkspace.shared.open(url) { self?.model?.error = L("Could not open System Settings. Try again.") }
        }
    }
}
