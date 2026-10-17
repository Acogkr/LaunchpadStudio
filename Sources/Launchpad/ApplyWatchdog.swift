import Foundation

enum ApplyWatchdog {
    static func start(owner: Int32, target: Int32) throws -> Process {
        guard owner > 1, target > 1 else { throw StudioError(L("Could not pause Dock.")) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \(owner) 2>/dev/null; do /bin/sleep 1; done; /bin/kill -CONT \(target) 2>/dev/null",
        ]
        try process.run()
        return process
    }
}
