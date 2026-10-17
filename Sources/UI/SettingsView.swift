import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: StudioModel
    @EnvironmentObject var updates: UpdateChecker
    @ObservedObject private var localization = Localization.shared
    @State private var layoutNotice = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        heading(L("Language"))
                        Spacer()
                        Picker(L("Language"), selection: $localization.selection) {
                            Text(L("System Default")).tag("system")
                            Divider()
                            ForEach(localization.sortedLanguages) { language in
                                Text(language.nativeName).tag(language.id)
                            }
                        }.labelsHidden().controlSize(.small).frame(width: 230)
                    }
                    detail(L("Choose the app language. Changes take effect immediately."))
                    detail(L("Existing folder names stay unchanged. Auto-sort creates new folders in the selected language."))
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        heading("Launchpad")
                        Spacer()
                        Text(model.baseline == nil ? L("Not connected") : L("Connected"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Text(model.source?.path ?? L("Not connected"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(model.source?.path ?? "")
                        .textSelection(.enabled)
                    detail(L("Works with the original Launchpad on macOS 13–15. macOS 26 and later are not supported."))
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        heading(L("Layout Files"))
                        Spacer()
                        Button(L("Import…")) { layoutAction { model.importLayout() } }
                            .controlSize(.small).disabled(model.baseline == nil)
                        Button(L("Export…")) { layoutAction { model.exportLayout() } }
                            .controlSize(.small).disabled(model.baseline == nil)
                    }
                    detail(L("Import or export a draft based on the same Launchpad layout."))
                    HStack {
                        detail(L("Edits are saved automatically."))
                        Spacer()
                        Button(L("Reset to Current Layout")) { layoutAction { model.resetDraft() } }
                            .controlSize(.small).disabled(model.baseline == nil)
                    }
                    if !layoutNotice.isEmpty { detail(layoutNotice) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        heading(L("Automatically check for updates"))
                        Spacer()
                        Toggle(L("Automatically check for updates"), isOn: $updates.automaticallyChecks)
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                            .frame(width: 110, alignment: .trailing)
                    }
                    HStack(spacing: 12) {
                        Text(L("Current Version {0}", AppVersion.current))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button(updates.actionTitle) { updates.performAction() }
                            .controlSize(.small).disabled(updates.isChecking)
                    }
                    detail(updates.status.message)
                    detail(L("Checks GitHub once a day. Downloads open on the release page."))
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        heading(L("About Launchpad Studio"))
                        Spacer()
                        Button(L("Open Data Folder")) { NSWorkspace.shared.open(model.dataRoot) }
                            .controlSize(.small)
                    }
                    detail(L("App lists and edits stay on this Mac. Update checks connect to GitHub without sending them."))
                    detail(L("Applying changes is experimental. It edits a private Launchpad format and restarts Dock. Apply and restore were tested on database copies; live Dock integration still needs testing on other Macs."))
                    detail(L("Requires macOS 13–15 and a compatible Launchpad layout. Tested locally on macOS 15.7.4."))
                }
            }.padding(24)
        }
        .frame(width: 520)
        .environment(\.locale, L10n.locale)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(model.busy)
        .onChange(of: localization.selection) { _ in layoutNotice = "" }
        .alert(L("Unable to Complete"), isPresented: Binding(
            get: { model.settingsWindowActive && model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button(L("OK"), role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold))
    }
    private func layoutAction(_ action: () -> Void) {
        model.notice = ""
        action()
        layoutNotice = model.notice
    }
    private func detail(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
