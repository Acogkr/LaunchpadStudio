import AppKit
import SwiftUI

enum InspectorMetrics {
    static let inset: CGFloat = 16
    static let detailsHeight: CGFloat = 224
}

struct InspectorView: View {
    @EnvironmentObject var model: StudioModel
    @State var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let tile = model.tile {
                Text(tile.isFolder ? L("Folder Info") : L("App Info"))
                    .font(.system(size: 12, weight: .semibold)).frame(height: 16, alignment: .leading).padding(
                        .bottom, 16)
                HStack(spacing: 8) {
                    if tile.isFolder {
                        FolderThumbnail(ids: tile.appIDs, size: 48)
                    } else if let id = tile.appIDs.first {
                        AppIcon(id: id, size: 48)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tile.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).help(tile.name)
                        if tile.isFolder {
                            Text(L("Apps: {0}", tile.appIDs.count)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 48, alignment: .leading).padding(.bottom, 16)
                if tile.isFolder {
                    Text(L("Name")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 8)
                    HStack(spacing: 8) {
                        TextField(L("Folder Name"), text: $name).textFieldStyle(.roundedBorder).font(.system(size: 12))
                            .id(tile.id).onSubmit { saveName(tile) }.accessibilityLabel(L("Folder Name"))
                        Button {
                            saveName(tile)
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .buttonStyle(.bordered).controlSize(.small).help(L("Save Folder Name")).accessibilityLabel(
                            L("Save Folder Name"))
                    }.disabled(!model.canEdit)
                    Divider().padding(.vertical, 16)
                    HStack {
                        Text(L("Included Apps")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        if model.canEdit {
                            Button(L("Sort by Name")) { sortApps(tile) }.buttonStyle(.borderless).font(
                                .system(size: 11))
                        }
                    }.frame(height: 16).padding(.bottom, 8)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(tile.appIDs, id: \.self) { id in
                                    if let app = model.app(id) {
                                        Button {
                                            model.selectedApp = id
                                        } label: {
                                            HStack(spacing: 8) {
                                                AppIcon(id: id, size: 24)
                                                Text(app.name).font(.system(size: 12)).lineLimit(1).help(app.name)
                                                Spacer(minLength: 0)
                                                if model.preferences.locked.contains(id) {
                                                    Image(systemName: "lock.fill").font(.system(size: 9))
                                                        .foregroundStyle(.secondary)
                                                }
                                            }.padding(.horizontal, 8).frame(height: 32)
                                                .background(
                                                    model.selectedApp == id ? Palette.selection : .clear,
                                                    in: RoundedRectangle(cornerRadius: 4)
                                                )
                                                .contentShape(Rectangle())
                                        }.buttonStyle(.plain).id(id).accessibilityLabel(app.name)
                                            .accessibilityAddTraits(model.selectedApp == id ? [.isSelected] : [])
                                            .onDrag { NSItemProvider(object: String(id) as NSString) }
                                            .contextMenu { AppContextMenu(id: id, tileID: tile.id) }
                                    }
                                }
                            }
                            if tile.appIDs.isEmpty {
                                VStack(spacing: 8) {
                                    Text(L("Empty folder")).foregroundStyle(.secondary)
                                    Button(L("Delete Empty Folder")) { model.removeEmpty(tile.id) }.buttonStyle(
                                        .bordered)
                                }.font(.system(size: 12)).frame(maxWidth: .infinity).padding(.vertical, 24)
                            }
                        }.padding(.horizontal, -8)
                            .onAppear { if let id = model.selectedApp { proxy.scrollTo(id, anchor: .center) } }
                            .onChange(of: model.selectedApp) { id in if let id { proxy.scrollTo(id, anchor: .center) } }
                    }
                } else {
                    Spacer(minLength: 0)
                }
                Divider().padding(.vertical, 16)
                Group {
                    if let app = model.inspectedApp {
                        AppDetailsView(app: app, showsName: tile.isFolder)
                    } else {
                        Text(L("Select an app to view its details."))
                            .font(.system(size: 11)).foregroundStyle(.secondary).frame(
                                maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(height: InspectorMetrics.detailsHeight, alignment: .topLeading)
                    .transaction { $0.animation = nil }
            } else {
                Spacer()
                Text(L("Select an app or folder.")).foregroundStyle(.secondary)
                Spacer()
            }
        }.padding(InspectorMetrics.inset).background(Palette.chrome)
            .onAppear { name = model.tile?.name ?? "" }
            .onChange(of: model.selectedTile) { _ in name = model.tile?.name ?? "" }
            .onChange(of: model.tile?.name) { value in name = value ?? "" }
    }
    func saveName(_ tile: Tile) {
        let proposedName = name
        NSApp.keyWindow?.makeFirstResponder(nil)
        model.rename(tile.id, to: proposedName)
    }
    func sortApps(_ tile: Tile) {
        model.edit { layout in
            for p in layout.pages.indices {
                if let t = layout.pages[p].tiles.firstIndex(where: { $0.id == tile.id }) {
                    layout.pages[p].tiles[t].appIDs.sort {
                        L10n.ordered(model.app($0)?.name ?? "", model.app($1)?.name ?? "")
                    }
                }
            }
        }
    }
}

struct AppDetailsView: View {
    @EnvironmentObject var model: StudioModel
    var app: AppRecord
    var showsName: Bool
    var body: some View {
        let reason = Classifier.classify(app, rules: model.preferences.rules).reason
        VStack(alignment: .leading, spacing: 8) {
            Text(showsName ? app.name : " ").font(.system(size: 12, weight: .semibold))
                .lineLimit(2).frame(height: 32, alignment: .topLeading).help(showsName ? app.name : "")
                .accessibilityHidden(!showsName)
            HStack {
                Text(L("Why this category")).font(.system(size: 11, weight: .medium))
                Spacer()
                IconButton(
                    icon: model.preferences.locked.contains(app.id) ? "lock.fill" : "lock.open",
                    help: model.preferences.locked.contains(app.id) ? L("Unpin Category") : L("Pin Current Category")
                ) { model.lock(app.id) }
            }.frame(height: 24)
            Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                .frame(height: 30, alignment: .topLeading).help(reason)
            Text(app.bundleID).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(height: 14, alignment: .leading).help(app.bundleID)
                .textSelection(.enabled)
            Menu(L("Move to Another Folder")) { MoveMenu(ids: [app.id]) }.controlSize(.small).disabled(!model.canEdit)
                .frame(height: 24)
            AppRemovalAction(id: app.id)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppRemovalAction: View {
    @EnvironmentObject var model: StudioModel
    var id: Int64
    var body: some View {
        let target = model.removalApp(for: id)
        let protected = model.app(id).map { model.isDeletionProtected($0.bundleID) } ?? false
        let explanation =
            model.app(id)?.bundleID == model.removalScanner.protectedBundleID
            ? L("Launchpad Studio cannot remove itself.")
            : protected
                ? L("Protected. Right-click the app to turn off deletion protection.")
                : L("This app cannot be removed from here.")
        VStack(alignment: .leading, spacing: 8) {
            Button(L("Remove App…"), role: .destructive) {
                if let target { model.prepareRemoval(target) }
            }.buttonStyle(.bordered).controlSize(.small).disabled(target == nil || protected || model.busy).frame(
                height: 22)
            Text(target == nil || protected ? explanation : " ").font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2).frame(height: 28, alignment: .topLeading).help(
                    target == nil || protected ? explanation : ""
                )
                .accessibilityHidden(target != nil && !protected)
        }.frame(height: 58, alignment: .topLeading)
    }
}

struct MoveMenu: View {
    @EnvironmentObject var model: StudioModel
    var ids: [Int64]
    var body: some View {
        ForEach(model.folders.sorted { L10n.ordered($0.name, $1.name) }) { folder in
            Button(folder.name) { model.moveApps(ids, to: folder.id) }.disabled(
                ids.allSatisfy { folder.appIDs.contains($0) })
        }
        Divider()
        Button(L("Move Out of Folder")) { model.moveApps(ids, to: "__root__") }
            .disabled(!ids.contains { id in model.folders.contains { $0.appIDs.contains(id) } })
    }
}
struct AppContextMenu: View {
    @EnvironmentObject var model: StudioModel
    var id: Int64
    var tileID: String?
    var body: some View {
        if model.canEdit {
            Menu(L("Move to Folder")) { MoveMenu(ids: [id]) }
            Button(model.preferences.locked.contains(id) ? L("Unpin Category") : L("Pin Current Category")) {
                model.lock(id)
            }
            if let tileID {
                Divider()
                Button(L("Move Earlier")) { model.reorderApp(id, in: tileID, by: -1) }
                Button(L("Move Later")) { model.reorderApp(id, in: tileID, by: 1) }
            }
        }
        if let path = model.app(id)?.path {
            Divider()
            Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        if let app = model.removalApp(for: id) {
            Divider()
            Toggle(
                L("Protect from Deletion"),
                isOn: Binding(
                    get: { model.isDeletionProtected(app.bundleID) },
                    set: { _ in model.toggleDeletionProtection(app.bundleID) })
            ).disabled(model.busy)
            Button(L("Remove App…"), role: .destructive) { model.prepareRemoval(app) }.disabled(
                model.busy || model.isDeletionProtected(app.bundleID))
        }
    }
}
