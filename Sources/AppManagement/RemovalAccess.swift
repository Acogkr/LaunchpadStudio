import AppKit
import Carbon

// Keep the original error domain/code for diagnosis; never infer access from translated text.
struct RemovalFailure: Codable, Equatable {
    enum Recovery: String, Codable { case appManagement, fileAccess, administrator, automation, cancelled, other }
    let domain: String
    let code: Int
    let underlyingDomain: String?
    let underlyingCode: Int?
    let recovery: Recovery

    init(_ error: Error, url: URL, kind: RemovalKind) {
        let outer = error as NSError
        var chain = [outer]
        while chain.count < 8, let next = chain.last?.userInfo[NSUnderlyingErrorKey] as? NSError,
            !chain.contains(where: { $0 === next })
        { chain.append(next) }
        domain = outer.domain
        code = outer.code
        underlyingDomain = chain.dropFirst().last?.domain
        underlyingCode = chain.dropFirst().last?.code
        if chain.contains(where: {
            ($0.domain == NSCocoaErrorDomain && $0.code == NSUserCancelledError)
                || ($0.domain == NSOSStatusErrorDomain && $0.code == -128)
        }) {
            recovery = .cancelled
        } else if chain.contains(where: { $0.domain == NSOSStatusErrorDomain && $0.code == -1743 }) {
            recovery = .automation
        } else if chain.contains(where: {
            ($0.domain == NSCocoaErrorDomain
                && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains($0.code))
                || ($0.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains($0.code))
                || ($0.domain == NSOSStatusErrorDomain && [-54, -5000, -10004].contains($0.code))
        }) {
            // Moving a file requires access to its parent. An app under a root-owned
            // vendor directory needs filesystem authorization, not just a TCC switch.
            recovery =
                FinderTrash.needsAuthorization(url)
                ? .administrator : (kind == .application ? .appManagement : .fileAccess)
        } else {
            recovery = .other
        }
    }
    var permitsFinderRetry: Bool { [.appManagement, .fileAccess, .administrator, .automation].contains(recovery) }
    var permitsAutomaticFinderRetry: Bool { [.appManagement, .fileAccess, .administrator].contains(recovery) }
    var guidance: String {
        switch recovery {
        case .appManagement: return L("macOS could not move this app. Retry with Finder and approve any system prompt.")
        case .fileAccess:
            return L("These files could not be accessed. Retry with Finder to continue through macOS authorization.")
        case .administrator:
            return L("This location requires administrator approval. Retry with Finder and approve the macOS dialog.")
        case .automation: return L("In Automation, expand Launchpad Studio and enable Finder, then retry.")
        case .cancelled: return L("Removal was cancelled. Remaining files were not moved.")
        case .other: return L("Some files could not be moved. Review the result and retry the remaining items.")
        }
    }
    var settingsURL: URL? {
        let section: String
        switch recovery {
        case .automation: section = "Privacy_Automation"
        default: return nil
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?" + section)
    }
    var settingsTitle: String {
        L("Open Finder Permissions…")
    }
    var finderActionTitle: String {
        recovery == .administrator ? L("Continue with Administrator Approval…") : L("Retry with Finder…")
    }
}

enum FinderTrash {
    static func needsAuthorization(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        // Do not mistake a stale or missing path for an authorization problem.
        guard FileManager.default.fileExists(atPath: parent.path) else { return false }
        return !FileManager.default.isWritableFile(atPath: parent.path)
    }
    // Arguments are Apple-event descriptors, never interpolated AppleScript or shell code.
    static let source = """
        on trashfile(thePath)
            set targetFile to POSIX file thePath
            with timeout of 300 seconds
                tell application id "com.apple.finder"
                    activate
                    set movedFile to delete targetFile
                    try
                        if movedFile is missing value then return ""
                        return POSIX path of (movedFile as alias)
                    on error messageText number errorNumber
                        -- Finder can return no value after a cancelled admin dialog.
                        if errorNumber is -2753 then return ""
                        error messageText number errorNumber
                    end try
                end tell
            end timeout
        end trashfile
        """
    static func request(for url: URL) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "trashfile"), forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: url.path), at: 1)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        return event
    }
    @MainActor static func recycle(_ url: URL) throws -> URL {
        guard let script = NSAppleScript(source: source) else { throw StudioError(L("Could not contact Finder.")) }
        defer { NSApp.activate(ignoringOtherApps: true) }
        var details: NSDictionary?
        let reply = script.executeAppleEvent(request(for: url), error: &details)
        if let details {
            let code = (details[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -2700
            let message = details[NSAppleScript.errorMessage] as? String ?? L("Could not contact Finder.")
            throw NSError(domain: NSOSStatusErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try destination(reply.stringValue, original: url)
    }
    static func destination(_ result: String?, original url: URL) throws -> URL {
        guard let path = result, !path.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) {
                throw NSError(
                    domain: NSCocoaErrorDomain, code: NSUserCancelledError,
                    userInfo: [NSLocalizedDescriptionKey: L("Removal was cancelled. Remaining files were not moved.")])
            }
            throw StudioError(L("Finder did not return the Trash location. Check Trash before trying again."))
        }
        guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: url.path),
            FileManager.default.fileExists(atPath: path)
        else { throw StudioError(L("The file was not moved to Trash.")) }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}
