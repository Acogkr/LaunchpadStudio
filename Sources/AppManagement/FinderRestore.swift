import AppKit
import Carbon

enum FinderRestore {
    // Finder's move command never replaces an existing item. If the final rename
    // cannot be completed, return the actual location so the UI can reveal it.
    static let source = """
        on restorefile(sourcePath, parentPath, destinationPath, originalName)
            set sourceFile to POSIX file sourcePath
            set parentFolder to POSIX file parentPath
            set destinationFile to POSIX file destinationPath
            with timeout of 300 seconds
                tell application id "com.apple.finder"
                    if exists destinationFile then error "An item already exists at the original location." number -48
                    activate
                    set movedFile to move sourceFile to parentFolder without replacing
                    if movedFile is missing value then error number -128
                    try
                        if name of movedFile is not originalName then set name of movedFile to originalName
                    end try
                    return POSIX path of (movedFile as alias)
                end tell
            end timeout
        end restorefile
        """
    static func request(_ source: URL, to destination: URL) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "restorefile"), forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        for (index, argument) in [
            source.path, destination.deletingLastPathComponent().path, destination.path, destination.lastPathComponent,
        ].enumerated() {
            arguments.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
        return event
    }
    @MainActor static func move(_ url: URL, to destination: URL) throws -> URL {
        guard let script = NSAppleScript(source: source) else { throw StudioError(L("Could not contact Finder.")) }
        defer { NSApp.activate(ignoringOtherApps: true) }
        var details: NSDictionary?
        let reply = script.executeAppleEvent(request(url, to: destination), error: &details)
        if let details {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: (details[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? -2700,
                userInfo: [
                    NSLocalizedDescriptionKey: details[NSAppleScript.errorMessage] as? String
                        ?? L("Could not contact Finder.")
                ])
        }
        guard let path = reply.stringValue, path.hasPrefix("/"), !FileManager.default.fileExists(atPath: url.path),
            FileManager.default.fileExists(atPath: path),
            URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
                == destination.deletingLastPathComponent().standardizedFileURL
        else {
            throw StudioError(L("Could not verify the restored location. Check Finder before retrying."))
        }
        return URL(fileURLWithPath: path)
    }
}
