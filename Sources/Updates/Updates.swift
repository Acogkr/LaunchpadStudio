import AppKit
import Combine
import Foundation

struct ReleaseVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ tag: String) {
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard tag.count <= 64, (2...3).contains(parts.count),
            parts.allSatisfy({
                !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && ($0.count == 1 || $0.first != "0")
            }),
            let major = Int(parts[0]), let minor = Int(parts[1]),
            let patch = parts.count == 3 ? Int(parts[2]) : 0
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct AppRelease: Equatable {
    let tag: String
    let version: ReleaseVersion
    var displayVersion: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
    // Construct links locally; never open a URL supplied in release notes or API metadata.
    var pageURL: URL { URL(string: "https://github.com/Acogkr/LaunchpadStudio/releases/tag/" + tag)! }
    init?(_ tag: String) {
        guard let version = ReleaseVersion(tag) else { return nil }
        self.tag = tag
        self.version = version
    }
}

enum UpdateCheckError: Error, Equatable {
    case offline, rateLimited, unavailable, invalidResponse, openFailed
    var message: String {
        switch self {
        case .offline: return L("Could not connect to GitHub. Check your internet connection and try again.")
        case .rateLimited: return L("GitHub is temporarily limiting update checks. Try again later.")
        case .openFailed: return L("Could not open the release page. Try again.")
        case .unavailable, .invalidResponse: return L("Could not check for updates. Try again later.")
        }
    }
}

enum UpdateStatus: Equatable {
    case idle, checking, current, noRelease
    case available(AppRelease)
    case failed(UpdateCheckError)
    var message: String {
        switch self {
        case .idle: return L("Check GitHub for a newer version.")
        case .checking: return L("Checking for updates…")
        case .current: return L("No newer version is available.")
        case .noRelease: return L("No public release is available to check.")
        case .available(let release): return L("Version {0} is available.", release.displayVersion)
        case .failed(let error): return error.message
        }
    }
}

enum GitHubUpdates {
    static let endpoint = URL(string: "https://api.github.com/repos/Acogkr/LaunchpadStudio/releases/latest")!
    static var request: URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("LaunchpadStudio", forHTTPHeaderField: "User-Agent")
        return request
    }
    static func decode(_ data: Data, statusCode: Int) throws -> AppRelease? {
        if statusCode == 404 { return nil }
        if statusCode == 403 || statusCode == 429 { throw UpdateCheckError.rateLimited }
        guard statusCode == 200 else { throw UpdateCheckError.unavailable }
        struct Payload: Decodable {
            let tagName: String
            let draft: Bool
            let prerelease: Bool
            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case draft, prerelease
            }
        }
        guard data.count <= 1_048_576, let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw UpdateCheckError.invalidResponse
        }
        guard !payload.draft, !payload.prerelease else { return nil }
        guard let release = AppRelease(payload.tagName) else { throw UpdateCheckError.invalidResponse }
        return release
    }
    static func load(_ completion: @escaping (Result<AppRelease?, UpdateCheckError>) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if error != nil {
                completion(.failure(.offline))
                return
            }
            guard let response = response as? HTTPURLResponse, let data else {
                completion(.failure(.invalidResponse))
                return
            }
            do { completion(.success(try decode(data, statusCode: response.statusCode))) } catch {
                completion(.failure(error as? UpdateCheckError ?? .invalidResponse))
            }
        }.resume()
    }
}

final class UpdateChecker: ObservableObject {
    typealias Loader = (@escaping (Result<AppRelease?, UpdateCheckError>) -> Void) -> Void
    @Published private(set) var status: UpdateStatus = .idle
    @Published private(set) var availableRelease: AppRelease?
    @Published var automaticallyChecks: Bool {
        didSet {
            defaults.set(automaticallyChecks, forKey: "StudioAutomaticallyChecksUpdates")
            if automaticallyChecks { check() }
        }
    }
    private let defaults: UserDefaults
    private let currentVersion: ReleaseVersion?
    private let loader: Loader
    private let now: () -> Date
    private let openURL: (URL) -> Bool
    private var timer: Timer?
    var isChecking: Bool { status == .checking }
    var actionTitle: String {
        if isChecking { return L("Checking for updates…") }
        if let release = availableRelease { return L("Update Available ({0})…", release.displayVersion) }
        return L("Check for Updates…")
    }
    init(defaults: UserDefaults = .standard, currentVersion: String = AppVersion.current,
         loader: @escaping Loader = GitHubUpdates.load, now: @escaping () -> Date = Date.init,
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.currentVersion = ReleaseVersion(currentVersion)
        self.loader = loader; self.now = now; self.openURL = openURL
        automaticallyChecks = defaults.object(forKey: "StudioAutomaticallyChecksUpdates") as? Bool ?? true
        if let tag = defaults.string(forKey: "StudioAvailableRelease"), let release = AppRelease(tag),
           let current = self.currentVersion, release.version > current {
            availableRelease = release
            status = .available(release)
        } else {
            defaults.removeObject(forKey: "StudioAvailableRelease")
        }
    }
    func start() {
        guard timer == nil else { return }
        check()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.check() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
    func check(manual: Bool = false) {
        guard manual || automaticallyChecks, !isChecking else { return }
        if !manual, let last = defaults.object(forKey: "StudioUpdateLastAttempt") as? Date {
            let interval: TimeInterval = defaults.bool(forKey: "StudioUpdateLastSucceeded") ? 86400 : 3600
            let elapsed = now().timeIntervalSince(last)
            if elapsed >= 0 && elapsed < interval { return }
        }
        guard currentVersion != nil else { status = .failed(.invalidResponse); return }
        status = .checking
        defaults.set(now(), forKey: "StudioUpdateLastAttempt")
        defaults.set(false, forKey: "StudioUpdateLastSucceeded")
        loader { [weak self] result in DispatchQueue.main.async { self?.receive(result) } }
    }
    private func receive(_ result: Result<AppRelease?, UpdateCheckError>) {
        switch result {
        case .success(let release):
            defaults.set(true, forKey: "StudioUpdateLastSucceeded")
            if let release, let currentVersion, release.version > currentVersion {
                availableRelease = release
                status = .available(release)
                defaults.set(release.tag, forKey: "StudioAvailableRelease")
            } else {
                availableRelease = nil
                status = release == nil ? .noRelease : .current
                defaults.removeObject(forKey: "StudioAvailableRelease")
            }
        case .failure(let error): status = .failed(error)
        }
    }
    func performAction() {
        if availableRelease != nil { openRelease() } else { check(manual: true) }
    }
    @discardableResult
    func openRelease() -> Bool {
        guard let release = availableRelease else { return false }
        guard openURL(release.pageURL) else { status = .failed(.openFailed); return false }
        // Opening the download page does not mean the update has been installed.
        return true
    }
}
