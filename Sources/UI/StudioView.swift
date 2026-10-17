import AppKit
import SwiftUI

struct StudioView: View {
    @EnvironmentObject var model: StudioModel
    @EnvironmentObject var updates: UpdateChecker
    @ObservedObject private var localization = Localization.shared
    @State var refreshPrompt = false
    @State var toastVisible = false
    @FocusState var searchFocused: Bool
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                topbar
                Divider()
                if model.baseline == nil {
                    EmptyStateView(
                        title: L("Could not read Launchpad"), symbol: "square.grid.3x3",
                        detail: model.error ?? L("Refresh to try again.")
                    ).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        Group {
                            switch model.selectedTab {
                            case "rules": RulesView()
                            case "backups": BackupsView()
                            default: PreviewView()
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if model.selectedTab == "preview" {
                            Divider()
                            InspectorView().frame(width: 268)
                        }
                    }
                }
                footer
            }
        }
        .id(localization.selection)
        .environment(\.locale, L10n.locale)
        .onChange(of: localization.selection) { _ in
            model.notice = ""
            toastVisible = false
        }
        .background(Palette.background).foregroundStyle(Palette.ink)
        .font(.system(size: 13))
        .frame(minWidth: 1150, minHeight: 730)
        .disabled(model.busy)
        .overlay {
            if model.busy && model.removalTarget == nil && model.cleanupPanel == nil {
                ZStack {
                    Color.black.opacity(0.12)
                    VStack(spacing: 16) {
                        ProgressView()
                        Text(model.busyText)
                    }.padding(30).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .overlay(alignment: .bottom) {
            if model.newAppToast && !model.newApplications.isEmpty {
                NewAppsToast().padding(.bottom, 56).padding(.leading, 202)

            }
        }

        .task(id: model.newAppToast) {
            guard model.newAppToast else { return }
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { model.newAppToast = false }
        }
        .task(id: model.notice) {
            guard !model.notice.isEmpty else {
                toastVisible = false
                return
            }
            toastVisible = true
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { toastVisible = false }
        }
        .alert(
            L("Unable to Complete"),
            isPresented: Binding(get: { model.error != nil && !model.settingsWindowActive }, set: { if !$0 { model.error = nil } })
        ) {
            Button(L("OK"), role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .alert(L("Refresh Launchpad?"), isPresented: $refreshPrompt) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Refresh")) { model.perform { try model.load() } }
        } message: {
            Text(L("Unapplied preview edits will be replaced with the current layout."))
        }
        .sheet(isPresented: $model.showApply) { ApplySheet() }
        .sheet(isPresented: $model.showChanges) { ChangesSheet() }
        .sheet(item: $model.cleanupPanel) { panel in CleanupSheet(panel: panel, model: model) }
        .sheet(item: $model.removalTarget, onDismiss: { model.closeRemoval() }) { _ in RemovalSheet() }
        .background {
            Group {
                Button("") {
                    model.selectedTab = "preview"
                    searchFocused = true
                }.keyboardShortcut("f", modifiers: .command)
            }.disabled(model.busy).hidden()
        }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Launchpad").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 7)
            sideItem("preview", L("Organize Apps"), "square.grid.2x2")
            sideItem("rules", L("Sorting Rules"), "line.3.horizontal.decrease")
            Text(L("Manage")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 7)
            sideItem(
                "backups", L("Backups"), "clock.arrow.circlepath",
                badge: model.backups.isEmpty ? nil : "\(model.backups.count)")
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.baseline == nil ? L("Not connected") : L("This Mac"))
                    Text(AppVersion.system).font(.system(size: 10))
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(18)
        }.frame(width: 202).background(SidebarMaterial())
    }
    func sideItem(_ id: String, _ title: String, _ icon: String, badge: String? = nil) -> some View {
        Button {
            model.selectedTab = id
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 17).foregroundStyle(.secondary)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 4)
                if let badge { Text(badge).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(model.selectedTab == id ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 1)
            .accessibilityAddTraits(model.selectedTab == id ? [.isSelected] : [])
    }
    var topbar: some View {
        HStack(spacing: 10) {
            Text("Launchpad Studio").font(.system(size: 13, weight: .semibold))
            Spacer()
            UpdateButton(updates: updates)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search"), text: $model.search).textFieldStyle(.plain).font(.system(size: 12)).focused(
                    $searchFocused
                )
                .onChange(of: model.search) { value in if !value.isEmpty { model.selectedTab = "preview" } }
                .onExitCommand { if model.search.isEmpty { searchFocused = false } else { model.search = "" } }
                .onSubmit { if let tile = model.previewTiles.first { model.selectTile(tile.id) } }
                if !model.search.isEmpty {
                    Button {
                        model.search = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help(L("Clear Search")).accessibilityLabel(L("Clear Search"))
                }
            }
            .padding(.horizontal, 7).frame(width: 170, height: 25)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.line.opacity(0.6), lineWidth: 0.5))
            IconButton(icon: "arrow.clockwise", help: L("Refresh Launchpad")) {
                if model.hasChanges { refreshPrompt = true } else { model.perform { try model.load() } }
            }
            Divider().frame(height: 17)
            Button(L("Open Launchpad")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Launchpad.app"))
            }
            .buttonStyle(.bordered).controlSize(.small)
        }.padding(.horizontal, 18).frame(height: 43).background(Palette.chrome)
    }
    var layoutStatus: String {
        guard model.baseline != nil else { return L("Launchpad unavailable") }
        if model.syncConflict { return L("Launchpad changed · Review before applying") }
        guard model.hasChanges else { return L("No changes") }
        return model.changeCount > 0 ? L("Apps changed: {0}", model.changeCount) : L("Layout changed")
    }
    var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(toastVisible ? model.notice : layoutStatus)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 1) {
                    IconButton(icon: "arrow.uturn.backward", help: L("Undo ⌘Z")) { model.undo() }.disabled(
                        model.undoStack.isEmpty || !model.canEdit)
                    IconButton(icon: "arrow.uturn.forward", help: L("Redo ⇧⌘Z")) { model.redo() }.disabled(
                        model.redoStack.isEmpty || !model.canEdit)
                }
                Button(L("Review Changes…")) { model.showChanges = true }.buttonStyle(.bordered).disabled(
                    !model.hasChanges)
                Button(L("Back Up & Apply…")) { model.showApply = true }.buttonStyle(.borderedProminent).disabled(
                    !model.hasChanges || model.baseline == nil
                )
                .help(L("Back up the current layout, then apply to Launchpad"))
            }.padding(.horizontal, 18).frame(height: 42).background(Palette.chrome)
        }
    }
}
