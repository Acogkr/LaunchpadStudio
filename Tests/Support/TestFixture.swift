import Foundation

enum TestFixture {
    static func source() throws -> URL {
        if CommandLine.arguments.contains("--live-data") { return try LaunchpadStore.locate() }
        guard let i = CommandLine.arguments.firstIndex(of: "--fixture"), CommandLine.arguments.count > i + 1 else {
            throw StudioError(
                "Run ./test.sh for synthetic data, or ./test.sh --live-data to test copies of this Mac's Launchpad.")
        }
        return URL(fileURLWithPath: CommandLine.arguments[i + 1])
    }
}
