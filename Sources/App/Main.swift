import AppKit

@main
enum Main {
    static func main() {
        #if STUDIO_TESTING
            if CommandLine.arguments.contains("--updates-test") {
                do {
                    try runUpdateTests()
                    exit(0)
                } catch {
                    fputs("FAIL: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            if CommandLine.arguments.contains("--cleanup-test") {
                do {
                    try runCleanupTests()
                    exit(0)
                } catch {
                    fputs("FAIL: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            if CommandLine.arguments.contains("--trash-test") {
                do {
                    try runTrashTests()
                    exit(0)
                } catch {
                    fputs("FAIL: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            if CommandLine.arguments.contains("--management-test") {
                do {
                    try runAppManagementTests()
                    exit(0)
                } catch {
                    fputs("FAIL: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            if CommandLine.arguments.contains("--audit-test") {
                do {
                    try runAuditTests()
                    exit(0)
                } catch {
                    fputs("FAIL: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            if CommandLine.arguments.contains("--model-test") {
                do {
                    try runModelTests()
                    exit(0)
                } catch {
                    fputs("FAIL: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            if CommandLine.arguments.contains("--localization-test") {
                do {
                    try runLocalizationTests()
                    exit(0)
                } catch {
                    fputs("FAIL: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            if CommandLine.arguments.contains("--self-test") {
                do {
                    try runSelfTests()
                    exit(0)
                } catch {
                    fputs("FAIL: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
        #endif
        if let i = CommandLine.arguments.firstIndex(of: "--write-icon"), CommandLine.arguments.count > i + 1 {
            let img = studioIcon()
            if let tiff = img.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                let data = bitmap.representation(using: .png, properties: [:])
            {
                try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
