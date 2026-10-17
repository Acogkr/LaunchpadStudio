import AppKit
import SwiftUI

struct ApplySheet: View {
    @EnvironmentObject var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Apply to Launchpad")).font(.system(size: 17, weight: .semibold))
            Text(
                L(
                    "Apps: {0} · Folders: {1} · Pages: {2}", model.apps.count, model.layout.folderCount,
                    model.layout.pages.count)
            ).foregroundStyle(.secondary)
            Divider()
            if model.syncConflict {
                Text(L("Launchpad changed while you were editing. Choose which layout to keep before applying."))
                    .lineSpacing(4)
            } else {
                Text(
                    L("The current layout will be backed up before applying.\nDock will briefly disappear and restart.")
                ).lineSpacing(4)
            }
            Text(
                L(
                    "Experimental: uses a private storage format. Apply and restore were tested on database copies; live Dock integration still needs testing on other Macs."
                )
            )
            .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            HStack {
                Spacer()
                Button(L("Cancel")) { model.showApply = false }.keyboardShortcut(.cancelAction).buttonStyle(.bordered)
                if model.syncConflict {
                    Button(L("Use Current Launchpad")) { model.resolveSyncConflict(keepEdits: false) }
                    Button(L("Keep My Edits")) { model.resolveSyncConflict(keepEdits: true) }
                } else {
                    Button(L("Apply to Launchpad")) { model.apply() }.buttonStyle(.borderedProminent)
                }
            }.padding(.top, 7)
        }.font(.system(size: 13)).padding(25).frame(width: 520).background(Palette.chrome)
    }
}
