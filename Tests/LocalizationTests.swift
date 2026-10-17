import Foundation

func runLocalizationTests() throws {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw StudioError("Localization test failed: " + message) }
        checks += 1
        print("PASS \(checks): \(message)")
    }
    defer { L10n.testCode = nil }
    let domain = "StudioLanguageTest-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    var preferred = ["fr", "ja"]
    let preference = Localization(defaults: defaults, preferredLanguages: { preferred })
    try check(preference.selection == "system" && preference.resolvedCode == "ja", "Initial language follows the first supported system preference")
    var notifications = 0
    let token = NotificationCenter.default.addObserver(forName: Localization.changed, object: preference, queue: nil) { _ in notifications += 1 }
    defer { NotificationCenter.default.removeObserver(token) }
    preferred = ["ko"]; preference.refreshSystemLanguage()
    try check(preference.resolvedCode == "ko" && preference.systemRevision == 1 && notifications == 1, "System language refresh updates views and menus")
    preference.selection = "en"
    preference.refreshSystemLanguage()
    try check(preference.resolvedCode == "en" && preference.systemRevision == 1, "System refresh does not override explicit language")
    let restored = Localization(defaults: defaults, preferredLanguages: { preferred })
    try check(restored.selection == "en", "Explicit language survives restart")
    preference.selection = "system"
    try check(preference.resolvedCode == "ko" && defaults.string(forKey: Localization.preferenceKey) == nil, "Returning to system language removes the override")
    let codes = ["en", "ko", "ja", "zh-Hans"]
    try check(Set(L10n.bundles.keys) == Set(codes), "Four localization bundles are present")
    let expectedVersion = ProcessInfo.processInfo.environment["STUDIO_EXPECTED_VERSION"]
    let bundledVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    try check(
        bundledVersion != nil && AppVersion.current == bundledVersion
            && (expectedVersion == nil || AppVersion.current == expectedVersion),
        "The app reports its bundled release version")
    let resolved = [
        (["en-GB"], "en"), (["ko-KR"], "ko"), (["ja-JP"], "ja"), (["zh-CN"], "zh-Hans"), (["zh-Hant-TW"], "zh-Hans"),
        (["fr", "ja"], "ja"), (["de-DE"], "en"),
    ]
    for (preferred, expected) in resolved {
        try check(L10n.resolve(preferred) == expected, "Language negotiation: \(preferred) → \(expected)")
    }
    try check(L10n.text("No changes", code: "unknown") == "No changes", "Unsupported locales fall back to English")
    try check(
        L10n.format("{1} / {0} / {1}", arguments: ["Folder {1}", "B"], locale: Locale(identifier: "en"))
            == "B / Folder {1} / B", "Placeholder reordering preserves literal braces in user text")
    var keySet: Set<String>?
    let status = ["en": "No changes", "ko": "변경 없음", "ja": "変更なし", "zh-Hans": "无更改"]
    let development = ["en": "Development", "ko": "개발", "ja": "開発", "zh-Hans": "开发"]
    let utilities = ["en": "System Tools", "ko": "시스템 도구", "ja": "システムツール", "zh-Hans": "系统工具"]
    let exampleApps = [
        AppRecord(
            id: 1, name: "Xcode", bundleID: "com.apple.dt.Xcode", category: "public.app-category.developer-tools",
            uuid: "xcode"),
        AppRecord(id: 2, name: "ディスクユーティリティ", bundleID: "com.apple.DiskUtility", category: "", uuid: "disk"),
        AppRecord(
            id: 3, name: "Tool 10", bundleID: "org.example.tool10", category: "public.app-category.utilities",
            uuid: "tool10"),
        AppRecord(
            id: 4, name: "Tool 2", bundleID: "org.example.tool2", category: "public.app-category.utilities",
            uuid: "tool2"),
    ]
    let customLayout = Layout(pages: [LayoutPage(tiles: [Tile(name: "개인 / 個人 / 个人 {0}", appIDs: [1, 2, 3, 4])])])
    let originalData = try JSONEncoder().encode(customLayout)
    for code in codes {
        L10n.testCode = code
        let resource = L10n.bundles[code]!.url(forResource: "Localizable", withExtension: "strings")!
        let dictionary =
            try PropertyListSerialization.propertyList(from: Data(contentsOf: resource), format: nil)
            as! [String: String]
        let keys = Set(dictionary.keys)
        if let keySet {
            try check(keys == keySet, "\(code): all translation keys match English")
        } else {
            keySet = keys
        }
        try check(
            dictionary.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            "\(code): no empty translations")
        try check(L("No changes") == status[code], "\(code): actual bundle lookup returns the translated status")
        try check(
            !L("Apps: {0} · Folders: {1} · Pages: {2}", 97, 11, 1).contains("{0}"),
            "\(code): runtime count placeholders resolve")
        try check(
            Classifier.classify(exampleApps[0], rules: []).folder == development[code],
            "\(code): generated folder uses the current language")
        try check(
            Classifier.classify(exampleApps[1], rules: []).folder == utilities[code],
            "\(code): Disk Utility is recognized independently of its translated app name")
        try check(L10n.ordered("Tool 2", "Tool 10"), "\(code): numeric app names use natural ordering")
        try check(L10n.ordered("app 2", "App 10"), "\(code): ordering handles case consistently")
        let proposal = Classifier.propose(
            apps: exampleApps, rules: [], current: customLayout, locked: [], preserveFolders: false)
        try proposal.validated(for: exampleApps)
        let names = proposal.tiles.first { $0.name == utilities[code] }!.appIDs
        try check(
            names.firstIndex(of: 4)! < names.firstIndex(of: 3)!, "\(code): actual proposal puts Tool 2 before Tool 10")
        let preserved = Classifier.propose(
            apps: exampleApps, rules: [], current: customLayout, locked: [], preserveFolders: true)
        try check(
            preserved.tiles[0].name == customLayout.tiles[0].name && preserved.appIDs == customLayout.appIDs,
            "\(code): user folder names and preserved order survive language changes")
        let decoded = try JSONDecoder().decode(Layout.self, from: originalData)
        try check(
            decoded.semantic == customLayout.semantic, "\(code): existing saved layout data is language independent")
        let rule = Rule(keyword: "Xcode", folder: "My Work / 開発 / 개발")
        try check(
            Classifier.classify(exampleApps[0], rules: [rule]).folder == rule.folder,
            "\(code): custom rule folder names are never translated")
        try check(
            L10n.backupReason("수동 백업") == L("Manual Backup") && L10n.backupReason("manual") == L("Manual Backup"),
            "\(code): legacy and new backup reasons localize without changing stored records")
        try check(
            !L10n.date(Date(timeIntervalSince1970: 0)).isEmpty, "\(code): backup dates format in the selected locale")
    }
    print("SUCCESS: \(checks) localization checks passed. No live Launchpad or user preferences were changed.")
}
