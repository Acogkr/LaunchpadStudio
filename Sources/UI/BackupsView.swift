import AppKit
import SwiftUI

struct BackupsView: View {
    @EnvironmentObject var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PageHeading(title: L("Backups"), subtitle: L("The current layout is backed up before every apply."))
                Spacer()
                Button(L("Back Up Now")) { model.manualBackup() }.buttonStyle(.bordered)
            }.padding(.bottom, 25)
            HStack {
                Text(L("Backups: {0}", model.backups.count)).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(L("Show in Finder")) {
                    if let manager = model.backupManager { NSWorkspace.shared.open(manager.root) }
                }
                .buttonStyle(.borderless).font(.system(size: 12))
            }.padding(.bottom, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.backups) { record in
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive").font(.system(size: 23, weight: .light)).foregroundStyle(
                                .secondary
                            ).frame(width: 35)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.backupReason(record.reason)).font(.system(size: 13, weight: .medium))
                                Text(L10n.date(record.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(L("Apps: {0} · Folders: {1}", record.appCount, record.folderCount)).font(
                                .system(size: 11)
                            ).foregroundStyle(.secondary)
                            Button(L("Load Layout")) { model.previewBackup(record) }.buttonStyle(.bordered).controlSize(
                                .small)
                        }.padding(.vertical, 16).padding(.horizontal, 3)
                        Divider()
                    }
                }
                if model.backups.isEmpty {
                    VStack(spacing: 8) {
                        Text(L("No backups yet."))
                        Text(L("Choose “Back Up Now” to save the current layout.")).font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 75)
                }
            }
            Text(L("Review before applying. Newly installed apps are kept; uninstalled apps are skipped."))
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 16)
        }.padding(28)
    }
}
