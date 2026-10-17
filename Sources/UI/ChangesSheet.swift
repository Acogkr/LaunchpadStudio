import AppKit
import SwiftUI

struct ChangesSheet: View {
    @EnvironmentObject var model: StudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("Changes")).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(L("Close")) { model.showChanges = false }.keyboardShortcut(.cancelAction).buttonStyle(.bordered)
            }
            if model.changeCount > 0 {
                Text(L("Apps changing folder or position: {0}", model.changeCount)).font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.changeCount == 0 {
                        Text(model.hasChanges ? L("Folder or page structure changed") : L("No changes to display"))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                    ForEach(
                        model.apps.filter { model.layout.location($0.id) != model.baseline?.layout.location($0.id) }
                    ) { app in
                        HStack(spacing: 9) {
                            AppIcon(id: app.id, size: 25)
                            Text(app.name).frame(maxWidth: .infinity, alignment: .leading)
                            Text(model.baseline?.layout.label(app.id) ?? "").foregroundStyle(.secondary).frame(
                                width: 120, alignment: .trailing)
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            Text(model.layout.label(app.id)).frame(width: 120, alignment: .leading)
                        }.font(.system(size: 12)).padding(.vertical, 7)
                        Divider()
                    }
                }
            }
        }.padding(24).frame(width: 650, height: 550).background(Palette.chrome)
    }
}
