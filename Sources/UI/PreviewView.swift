import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PreviewView: View {
    @EnvironmentObject var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Organize Apps")).font(.system(size: 20, weight: .semibold))
                    Text(
                        L(
                            "Apps: {0} · Folders: {1} · Pages: {2}", model.apps.count, model.layout.folderCount,
                            model.layout.pages.count)
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Sort by Name")) { model.sortPageByName() }.buttonStyle(.borderless).font(.system(size: 12))
                    .help(L("Sort the current preview page by name"))
                Button {
                    model.createFolder()
                } label: {
                    Label(L("New Folder"), systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless).font(.system(size: 12))
                Button(L("Auto-sort")) { model.classify() }.buttonStyle(.bordered)
            }.padding(.bottom, 21)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 3), spacing: 15) {
                        ForEach(model.previewTiles) { tile in FolderCard(tile: tile).id(tile.id) }
                    }.padding(.vertical, 5)
                    if model.previewTiles.isEmpty && !model.searchQuery.isEmpty {
                        EmptyStateView(
                            title: L("No apps found"), symbol: "magnifyingglass", detail: L("Try another search.")
                        ).padding(25)
                    }
                }
                .onAppear { if let id = model.selectedTile { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: model.selectedTile) { id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }
            if model.searchQuery.isEmpty {
                HStack(spacing: 5) {
                    Spacer()
                    ForEach(Array(model.layout.pages.indices), id: \.self) { page in
                        Button {
                            model.pageIndex = page
                            model.selectedTile = model.layout.pages[page].tiles.first?.id
                            model.selectedApp = nil
                        } label: {
                            Circle().fill(
                                page == model.pageIndex ? Color.primary.opacity(0.65) : Color.secondary.opacity(0.25)
                            ).frame(width: 6, height: 6).padding(4)
                        }.buttonStyle(.plain).accessibilityLabel(L("Page {0}", page + 1))
                    }
                    Text(
                        "\((model.pageIndex+1).formatted(.number.locale(L10n.locale))) / \(max(1,model.layout.pages.count).formatted(.number.locale(L10n.locale)))"
                    ).monospacedDigit().padding(.leading, 5)
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 15)
            }
        }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)
    }
}

struct FolderThumbnail: View {
    var ids: [Int64]
    var size: CGFloat = 70
    var body: some View {
        let mini = (size - 20) / 3
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(mini), spacing: 3), count: 3), spacing: 3) {
            ForEach(Array(ids.prefix(9)), id: \.self) { id in AppIcon(id: id, size: mini) }
            ForEach(0..<max(0, 9 - ids.count), id: \.self) { _ in Color.clear.frame(width: mini, height: mini) }
        }
        .padding(7).frame(width: size, height: size)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.38), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.line.opacity(0.45), lineWidth: 0.5))
    }
}

struct FolderCard: View {
    @EnvironmentObject var model: StudioModel
    var tile: Tile
    @State var target = false
    var selected: Bool { model.selectedTile == tile.id }
    var body: some View {
        Button {
            model.selectTile(tile.id)
        } label: {
            VStack(spacing: 4) {
                Group {
                    if tile.isFolder {
                        FolderThumbnail(ids: tile.appIDs)
                    } else if let id = tile.appIDs.first {
                        AppIcon(id: id, size: 66).frame(width: 70, height: 70)
                    }
                }
                .padding(5)
                .background(
                    selected || target ? Palette.selection.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9).strokeBorder(target ? Color.accentColor : .clear, lineWidth: 2))
                Text(tile.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(selected ? .white : Color.primary)
                    .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                Text(tile.isFolder ? L("Apps: {0}", tile.appIDs.count) : L("App")).font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(tile.isFolder ? L("{0}, apps: {1}", tile.name, tile.appIDs.count) : tile.name)
            .accessibilityAddTraits(selected ? [.isSelected] : []).help(tile.name)
            .contextMenu {
                if !tile.isFolder, let id = tile.appIDs.first {
                    AppContextMenu(id: id, tileID: nil)
                    Divider()
                }
                if model.canEdit {
                    Button(L("Move Earlier")) { model.reorderTile(tile.id, by: -1) }
                    Button(L("Move Later")) { model.reorderTile(tile.id, by: 1) }
                    Menu(L("Move to Page")) {
                        ForEach(Array(model.layout.pages.indices), id: \.self) { p in
                            Button(L("Page {0}", p + 1)) { model.moveTile(tile.id, page: p) }
                        }
                        Button(L("New Page")) { model.moveTile(tile.id, page: model.layout.pages.count) }
                    }
                    if tile.appIDs.isEmpty {
                        Button(L("Delete Empty Folder"), role: .destructive) { model.removeEmpty(tile.id) }
                    }
                }
            }
            .onDrop(of: [UTType.text], isTargeted: $target) { providers in
                guard model.canEdit, tile.isFolder, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let value = item as? String, let id = Int64(value) else { return }
                    DispatchQueue.main.async { model.moveApps([id], to: tile.id) }
                }
                return true
            }
    }
}
