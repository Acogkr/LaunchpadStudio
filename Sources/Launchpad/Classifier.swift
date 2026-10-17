import Foundation

struct Rule: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var keyword: String
    var folder: String
    var enabled = true
}
struct Classification {
    var folder: String
    var reason: String
    var confident: Bool
}
enum Classifier {
    static var categories: [String] {
        [
            L("Development"), L("Productivity"), L("Communication"), L("Music & Audio"), L("Photos & Design"),
            L("Video"), L("Games"), L("Internet"), L("System Tools"), L("Lifestyle"), L("Uncategorized"),
        ]
    }
    static func style(_ name: String) -> (String, String) {
        switch name {
        case L("Development"), L("Developer Tools"): return ("chevron.left.forwardslash.chevron.right", "blue")
        case L("Productivity"): return ("doc.text.fill", "teal")
        case L("Communication"): return ("bubble.left.and.bubble.right.fill", "purple")
        case L("Music & Audio"): return ("waveform", "pink")
        case L("Photos & Design"): return ("paintpalette.fill", "orange")
        case L("Video"): return ("play.rectangle.fill", "indigo")
        case L("Games"): return ("gamecontroller.fill", "purple")
        case L("Internet"): return ("globe", "blue")
        case L("System Tools"), L("Other"): return ("gearshape.2.fill", "gray")
        case L("Lifestyle"): return ("sun.max.fill", "orange")
        case L("Uncategorized"): return ("tray.fill", "gray")
        default: return ("folder.fill", "teal")
        }
    }
    static func classify(_ app: AppRecord, rules: [Rule]) -> Classification {
        let text = (app.name + " " + app.bundleID).lowercased()
        for rule in rules where rule.enabled && !rule.keyword.isEmpty && text.contains(rule.keyword.lowercased()) {
            return Classification(
                folder: rule.folder, reason: L("Custom rule · Contains “{0}”", rule.keyword), confident: true)
        }
        let known: [(String, [String])] = [
            (
                L("Development"),
                [
                    "codex", "xcode", "jetbrains", "android.studio", "vscode", "claude-code", "terminal", "utm",
                    "scripteditor", "automator",
                ]
            ),
            (
                L("Productivity"),
                [
                    "notion", "com.microsoft.word", "powerpoint", "google.drive", "notes", "reminders",
                    "com.apple.ical", "chatgpt", "claudefordesktop", "textedit", "freeform", "stickies",
                ]
            ),
            (L("Communication"), ["kakao", "discord", "facetime", "mobilesms", "apple.mail", "addressbook"]),
            (
                L("Music & Audio"),
                [
                    "music", "garageband", "tonex", "matribox", "sonicake", "ikmultimedia", "audiomidisetup",
                    "voicememos", "podcasts",
                ]
            ),
            (
                L("Photos & Design"),
                [
                    "photos", "photobooth", "giphy", "image_capture", "digitalcolormeter", "colorsync", "screenshot",
                    "preview",
                ]
            ),
            (L("Video"), ["quicktime", "apple.tv", "kollus"]),
            (L("Games"), ["steam", "prismlauncher", "chess", "moonlight", "세피리아"]),
            (L("Internet"), ["safari", "chrome", "firefox"]),
            (
                L("System Tools"),
                [
                    "tailscale", "teruten", "theine", "hidden bar", "minimalbar", "unarchiver", "1password",
                    "passwords", "systempreferences", "diskutility", "activitymonitor", "migrationassistant", "console",
                    "appstore", "siri", "screencontinuity",
                ]
            ),
            (
                L("Lifestyle"),
                [
                    "weather", "stocks", "maps", "findmy", "ibooks", "clock", "calculator", "apple.home", "dictionary",
                    "helpviewer",
                ]
            ),
        ]
        for (folder, words) in known where words.contains(where: text.contains) {
            return Classification(folder: folder, reason: L("App name and developer ID"), confident: true)
        }
        let categoryMap = [
            "developer-tools": L("Development"), "productivity": L("Productivity"), "business": L("Productivity"),
            "music": L("Music & Audio"), "video": L("Video"), "photography": L("Photos & Design"),
            "graphics-design": L("Photos & Design"), "social-networking": L("Communication"),
            "utilities": L("System Tools"), "education": L("Lifestyle"), "reference": L("Lifestyle"),
            "books": L("Lifestyle"), "travel": L("Lifestyle"),
        ]
        if app.category.contains("games") {
            return Classification(folder: L("Games"), reason: L("macOS app category"), confident: true)
        }
        let key = app.category.replacingOccurrences(of: "public.app-category.", with: "")
        if let folder = categoryMap[key] {
            return Classification(folder: folder, reason: L("macOS app category · {0}", key), confident: true)
        }
        return Classification(
            folder: L("Uncategorized"), reason: L("Not enough information to categorize this app"), confident: false)
    }
    static func propose(apps: [AppRecord], rules: [Rule], current: Layout, locked: Set<Int64>, preserveFolders: Bool)
        -> Layout
    {
        var kept: [Tile] = []
        var assigned = Set<Int64>()
        for var tile in current.tiles {
            let ids = tile.appIDs.filter { locked.contains($0) || (preserveFolders && tile.isFolder) }
            if !ids.isEmpty {
                if tile.appIDs != ids {
                    let retained = Set(ids)
                    tile.remapApps { retained.contains($0) ? $0 : nil }
                }
                kept.append(tile)
                assigned.formUnion(ids)
            } else if preserveFolders && tile.isFolder && tile.appIDs.isEmpty {
                kept.append(tile)
            }
        }
        var buckets: [String: [AppRecord]] = [:]
        for app in apps where !assigned.contains(app.id) {
            buckets[classify(app, rules: rules).folder, default: []].append(app)
        }
        let names =
            categories.filter { buckets[$0] != nil }
            + buckets.keys.filter { !categories.contains($0) }.sorted(by: L10n.ordered)
        var tiles = kept
        for name in names {
            let ids = buckets[name]!.sorted { L10n.ordered($0.name, $1.name) }.map(\.id)
            if let i = tiles.firstIndex(where: { $0.isFolder && $0.name == name }) {
                tiles[i].appendApps(ids)
            } else {
                var t = Tile(name: name, appIDs: ids, symbol: style(name).0, color: style(name).1)
                t.repaginate()
                tiles.append(t)
            }
        }
        return Layout(
            pages: stride(from: 0, to: tiles.count, by: 35).map {
                LayoutPage(tiles: Array(tiles[$0..<min($0 + 35, tiles.count)]))
            })
    }
}
