import Combine
import Foundation

struct AppLanguage: Identifiable {
    let id: String
    let nativeName: String
}

final class Localization: ObservableObject {
    static let shared = Localization()
    static let preferenceKey = "StudioLanguage"
    static let changed = Notification.Name("StudioLanguageChanged")
    static let supported = [
        AppLanguage(id: "en", nativeName: "English"),
        AppLanguage(id: "ja", nativeName: "日本語"),
        AppLanguage(id: "ko", nativeName: "한국어"),
        AppLanguage(id: "zh-Hans", nativeName: "简体中文"),
    ]
    private let defaults: UserDefaults
    private let preferredLanguages: () -> [String]
    @Published private(set) var systemRevision = 0
    @Published var selection: String {
        didSet {
            guard selection != oldValue else { return }
            if selection == "system" {
                defaults.removeObject(forKey: Self.preferenceKey)
            } else {
                defaults.set(selection, forKey: Self.preferenceKey)
            }
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
    init(defaults: UserDefaults = .standard, preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        let saved = defaults.string(forKey: Self.preferenceKey) ?? "system"
        selection = Self.supported.contains { $0.id == saved } ? saved : "system"
    }
    var resolvedCode: String {
        Self.supported.contains(where: { $0.id == selection }) ? selection : L10n.resolve(preferredLanguages())
    }
    func refreshSystemLanguage() {
        guard selection == "system" else { return }
        systemRevision += 1
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    var sortedLanguages: [AppLanguage] {
        Self.supported.sorted { L10n.ordered($0.nativeName, $1.nativeName) }
    }
}

enum L10n {
    // Only the self-test runner overrides this. Normal app selection lives in UserDefaults.
    static var testCode: String?
    static func resolve(_ preferred: [String]) -> String {
        for identifier in preferred {
            let base =
                identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first.map(
                    String.init) ?? ""
            if base == "zh" { return "zh-Hans" }
            if ["en", "ko", "ja"].contains(base) { return base }
        }
        return "en"
    }
    static var code: String {
        if let testCode { return testCode }
        if let selected = UserDefaults.standard.string(forKey: Localization.preferenceKey),
            Localization.supported.contains(where: { $0.id == selected })
        {
            return selected
        }
        return resolve(Locale.preferredLanguages)
    }
    static var locale: Locale { Locale(identifier: code) }
    static let bundles: [String: Bundle] = Dictionary(
        uniqueKeysWithValues: Localization.supported.compactMap { language in
            guard let url = Bundle.main.url(forResource: language.id, withExtension: "lproj"),
                let bundle = Bundle(url: url)
            else { return nil }
            return (language.id, bundle)
        })
    static func text(_ key: String, code: String? = nil) -> String {
        let english = bundles["en"]?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
        return bundles[code ?? self.code]?.localizedString(forKey: key, value: english, table: "Localizable") ?? english
    }
    static let placeholders = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
    static func format(_ template: String, arguments: [Any], locale: Locale) -> String {
        let source = template as NSString
        var result = template
        // Replacing from the end prevents inserted user text from being interpreted as placeholders.
        for match in placeholders.matches(in: template, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let index = Int(source.substring(with: match.range(at: 1))), arguments.indices.contains(index),
                let range = Range(match.range, in: result)
            else { continue }
            let value: String
            if let number = arguments[index] as? Int {
                value = number.formatted(.number.locale(locale))
            } else if let number = arguments[index] as? Int64 {
                value = number.formatted(.number.locale(locale))
            } else {
                value = String(describing: arguments[index])
            }
            result.replaceSubrange(range, with: value)
        }
        return result
    }
    static func ordered(_ lhs: String, _ rhs: String) -> Bool {
        let result = lhs.compare(
            rhs, options: [.numeric, .caseInsensitive, .widthInsensitive], range: nil, locale: locale)
        return result == .orderedSame ? lhs < rhs : result == .orderedAscending
    }
    static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }
    static func backupReason(_ reason: String) -> String {
        // Legacy records remain readable without rewriting their metadata or hashes.
        switch reason {
        case "manual", "수동 백업": return L("Manual Backup")
        case "before-apply", "적용 전 자동 백업": return L("Automatic Backup")
        default: return reason
        }
    }
}

// swift-format-ignore: AlwaysUseLowerCamelCase
func L(_ key: String, _ arguments: Any...) -> String {
    L10n.format(L10n.text(key), arguments: arguments, locale: L10n.locale)
}

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    static var system: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
