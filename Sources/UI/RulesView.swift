import AppKit
import SwiftUI

struct RulesView: View {
    @EnvironmentObject var model: StudioModel
    @State var keyword = ""
    @State var folder = L("Development")
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeading(
                    title: L("Sorting Rules"),
                    subtitle: L("Custom rules run first. Other apps are sorted using app information."))
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L("Custom Rules")).fontWeight(.semibold)
                        Spacer()
                        Text(L("Applied from top to bottom")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        TextField(L("App name or Bundle ID contains"), text: $keyword).textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField(L("Folder Name"), text: $folder).textFieldStyle(.roundedBorder).frame(width: 155)
                        Button(L("Add")) { addRule() }.buttonStyle(.bordered)
                    }
                    VStack(spacing: 0) {
                        if model.preferences.rules.isEmpty {
                            Text(L("No rules")).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(
                                .vertical, 27)
                        }
                        ForEach(model.preferences.rules) { rule in
                            HStack(spacing: 10) {
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: {
                                            model.preferences.rules.first(where: { $0.id == rule.id })?.enabled ?? false
                                        },
                                        set: { value in
                                            if let i = model.preferences.rules.firstIndex(where: { $0.id == rule.id }) {
                                                model.preferences.rules[i].enabled = value
                                                model.savePreferences()
                                            }
                                        })
                                ).toggleStyle(.checkbox).labelsHidden().accessibilityLabel(
                                    L("Enable rule {0}", rule.keyword))
                                Text(L("Contains “{0}”", rule.keyword)).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading).help(
                                        L("Contains “{0}”", rule.keyword))
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                Text(rule.folder).lineLimit(1).truncationMode(.middle).frame(
                                    width: 145, alignment: .leading
                                ).help(rule.folder)
                                IconButton(icon: "arrow.up", help: L("Increase Rule Priority")) {
                                    if let i = model.preferences.rules.firstIndex(where: { $0.id == rule.id }), i > 0 {
                                        model.preferences.rules.swapAt(i, i - 1)
                                        model.savePreferences()
                                    }
                                }.disabled(model.preferences.rules.first?.id == rule.id)
                                IconButton(icon: "minus", help: L("Delete Rule")) {
                                    model.preferences.rules.removeAll { $0.id == rule.id }
                                    model.savePreferences()
                                }
                            }.padding(.horizontal, 10).frame(height: 38)
                            Divider()
                        }
                    }.background(Palette.chrome.opacity(0.45)).overlay(
                        Rectangle().strokeBorder(Palette.line, lineWidth: 0.5))
                    Text(L("Example: jetbrains → Development. After editing rules, choose “Sort Again”.")).font(
                        .system(size: 11)
                    ).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(
                        L("Keep Existing Folders"),
                        isOn: Binding(
                            get: { model.preferences.preserveFolders },
                            set: {
                                model.preferences.preserveFolders = $0
                                model.savePreferences()
                            })
                    ).toggleStyle(.checkbox)
                    Text(L("Keep apps in folders and sort only the apps outside them.")).font(.system(size: 11))
                        .foregroundStyle(.secondary).padding(.leading, 19)
                    Text(L("Pinned apps keep their current folder: {0}", model.preferences.locked.count)).font(
                        .system(size: 12)
                    ).foregroundStyle(.secondary)
                }
                Divider()
                HStack(alignment: .top) {
                    Text(L("Apps without enough information go to “Uncategorized”.\nSorting runs on this Mac.")).font(
                        .system(size: 11)
                    ).foregroundStyle(.secondary).lineSpacing(4)
                    Spacer()
                    Button(L("Sort Again")) { model.classify() }.buttonStyle(.bordered)
                }
            }.padding(28)
        }
    }
    func addRule() {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !name.isEmpty, name.count <= 60, !name.contains("\0") else {
            model.error = L("Enter a keyword and a folder name of 1–60 characters.")
            return
        }
        model.preferences.rules.append(Rule(keyword: key, folder: name))
        model.savePreferences()
        keyword = ""
    }
}
