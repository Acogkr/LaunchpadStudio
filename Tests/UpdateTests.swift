import Foundation

func runUpdateTests() throws {
    L10n.testCode = "en"
    let domain = "org.example.studio-update-tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: domain)!
    defer {
        defaults.removePersistentDomain(forName: domain)
        L10n.testCode = nil
    }
    var checks = 0
    func check(_ value: @autoclosure () throws -> Bool, _ description: String) throws {
        guard try value() else { throw StudioError(description) }
        checks += 1
        print("PASS \(checks): \(description)")
    }
    func payload(_ tag: String, draft: Bool = false, prerelease: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "html_url": "file:///tmp/should-never-open", "body": "Untrusted release notes",
        ])
    }
    func rejects(_ expected: UpdateCheckError, data: Data = Data(), code: Int) throws -> Bool {
        do {
            _ = try GitHubUpdates.decode(data, statusCode: code)
            return false
        } catch { return error as? UpdateCheckError == expected }
    }
    try check(ReleaseVersion("v1.0") == ReleaseVersion("1.0.0"), "Two- and three-part versions compare equally")
    try check(
        ReleaseVersion("1.10.0")! > ReleaseVersion("1.9.9")!, "Minor versions compare numerically, not alphabetically")
    try check(
        ReleaseVersion("2.0")! > ReleaseVersion("1.99.99")! && ReleaseVersion("1.0.10")! > ReleaseVersion("1.0.9")!,
        "Major and patch upgrades compare numerically")
    try check(
        [
            "", "1", "1.0.0.1", "1..0", "v1.0-beta", "1.0+12", "01.0", "1.0/evil", "١.٠", "1.0 ",
            "1.0.99999999999999999999999999999999999",
        ].allSatisfy { ReleaseVersion($0) == nil },
        "Malformed, ambiguous and prerelease versions cannot become stable updates")
    let release = try GitHubUpdates.decode(payload("v1.2.0"), statusCode: 200)!
    try check(
        release.pageURL.absoluteString == "https://github.com/Acogkr/LaunchpadStudio/releases/tag/v1.2.0",
        "Release links use the fixed repository and ignore untrusted API URLs")
    try check(
        try GitHubUpdates.decode(payload("v2.0", draft: true), statusCode: 200) == nil
            && GitHubUpdates.decode(payload("v2.0", prerelease: true), statusCode: 200) == nil,
        "Draft and prerelease payloads are excluded")
    try check(
        try GitHubUpdates.decode(Data(), statusCode: 404) == nil,
        "Missing public releases are distinct from a current-version result")
    try check(
        try rejects(.rateLimited, code: 403) && rejects(.rateLimited, code: 429),
        "GitHub throttling has a useful recovery message")
    try check(
        try rejects(.unavailable, code: 500) && rejects(.unavailable, code: 401),
        "Server and authorization failures are not reported as up to date")
    try check(
        try rejects(.invalidResponse, data: Data("{}".utf8), code: 200)
            && rejects(.invalidResponse, data: payload("v1.2-beta"), code: 200), "Invalid success responses fail safely"
    )
    try check(
        try rejects(.invalidResponse, data: Data(repeating: 32, count: 1_048_577), code: 200),
        "Oversized responses are rejected")
    let request = GitHubUpdates.request
    try check(
        request.url == GitHubUpdates.endpoint && request.httpBody == nil
            && request.value(forHTTPHeaderField: "Authorization") == nil && request.timeoutInterval == 15,
        "Requests need no token and send no app list, edits or other request body")

    var date = Date(timeIntervalSince1970: 1_000_000)
    var pending: [(Result<AppRelease?, UpdateCheckError>) -> Void] = []
    var calls = 0
    var opened: [URL] = []
    let loader: UpdateChecker.Loader = { calls += 1; pending.append($0) }
    let updater = UpdateChecker(defaults: defaults, currentVersion: "1.0.1", loader: loader, now: { date },
        openURL: { opened.append($0); return true })
    func finish(_ result: Result<AppRelease?, UpdateCheckError>) throws {
        guard !pending.isEmpty else { throw NSError(domain: "UpdateTest", code: 1) }
        pending.removeFirst()(result)
        let deadline = Date().addingTimeInterval(2)
        while updater.isChecking && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try check(!updater.isChecking, "Response completes the request")
    }
    updater.check(); updater.check()
    try check(calls == 1, "Overlapping requests are coalesced")
    try finish(.success(release))
    try check(updater.availableRelease == release && updater.status == .available(release),
        "A newer release supplies the persistent toolbar button")
    updater.check()
    try check(calls == 1 && updater.availableRelease == release, "The daily cache retains the update button")
    defaults.set("1.2.0", forKey: "StudioUpdateNotifiedVersion")
    let restarted = UpdateChecker(defaults: defaults, currentVersion: "1.0.1", loader: loader, now: { date })
    restarted.check()
    try check(restarted.availableRelease == release && calls == 1,
        "Restart retains the button even when a legacy notification was already seen")
    updater.performAction()
    try check(opened == [release.pageURL] && updater.availableRelease == release && calls == 1,
        "Opening the release page never hides the button or installs an update")
    let blocked = UpdateChecker(defaults: defaults, currentVersion: "1.0.1", loader: loader, openURL: { _ in false })
    try check(!blocked.openRelease() && blocked.status == .failed(.openFailed) && blocked.availableRelease == release,
        "A browser failure preserves a usable update action")
    date = date.addingTimeInterval(86401)
    updater.check()
    try check(calls == 2 && updater.availableRelease == release, "Daily recheck keeps the known update visible")
    try finish(.failure(.offline))
    try check(updater.availableRelease == release && updater.status == .failed(.offline),
        "Network failure cannot erase a known update")
    date = date.addingTimeInterval(3599); updater.check()
    try check(calls == 2, "Failed requests back off for one hour")
    date = date.addingTimeInterval(2); updater.check()
    try check(calls == 3, "Failed requests retry after an hour")
    try finish(.success(release))
    updater.automaticallyChecks = false
    date = date.addingTimeInterval(86401); updater.check()
    try check(calls == 3 && updater.availableRelease == release && !UpdateChecker(defaults: defaults, loader: loader).automaticallyChecks,
        "Turning off automatic checks preserves the known update and the preference")
    updater.check(manual: true)
    try check(calls == 4, "Manual checking bypasses cache and disabled automation")
    try finish(.success(AppRelease("v1.0.1")))
    try check(updater.status == .current && updater.availableRelease == nil, "Equal versions never show an update")
    updater.check(manual: true); try finish(.success(AppRelease("v1.0")))
    try check(updater.availableRelease == nil, "Older releases never offer a downgrade")
    updater.check(manual: true); try finish(.success(nil))
    try check(updater.status == .noRelease && updater.availableRelease == nil, "No public release has its own status")
    updater.check(manual: true); try finish(.success(release))
    let updated = UpdateChecker(defaults: defaults, currentVersion: "1.2.0", loader: loader)
    try check(updated.availableRelease == nil && defaults.string(forKey: "StudioAvailableRelease") == nil,
        "Installing the offered version clears the update button")
    defaults.set("../../bad", forKey: "StudioAvailableRelease")
    let invalid = UpdateChecker(defaults: defaults, currentVersion: "1.0.1", loader: loader)
    try check(invalid.availableRelease == nil && defaults.string(forKey: "StudioAvailableRelease") == nil,
        "Corrupt cached versions cannot become links")
    date = date.addingTimeInterval(-172800); updater.automaticallyChecks = true
    try check(updater.isChecking, "Clock rollback cannot freeze update checking")
    try finish(.success(AppRelease("v1.4")))
    for language in ["ko", "en", "ja", "zh-Hans"] {
        L10n.testCode = language
        try check(!updater.actionTitle.contains("{0}") && !UpdateStatus.available(release).message.contains("{0}"),
            "Localized update actions interpolate correctly")
    }
    updater.stop(); restarted.stop()
    print("SUCCESS: \(checks) update checks passed. No network requests or user preferences were changed.")
}
