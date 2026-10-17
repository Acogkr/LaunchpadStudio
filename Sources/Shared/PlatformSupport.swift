import Foundation

enum PlatformSupport {
    static func supports(majorVersion: Int) -> Bool { (13...15).contains(majorVersion) }

    static func requireSupportedOS() throws {
        guard supports(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) else {
            throw StudioError(
                L("Launchpad Studio requires macOS 13, 14, or 15. macOS 26 and later use a different app browser."))
        }
    }
}
