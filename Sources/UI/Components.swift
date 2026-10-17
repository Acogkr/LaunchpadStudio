import AppKit
import SwiftUI

enum Palette {
    static let background = Color(nsColor: .controlBackgroundColor)
    static let chrome = Color(nsColor: .windowBackgroundColor)
    static let selection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    static let ink = Color.primary
    static let muted = Color.secondary
    static let line = Color(nsColor: .separatorColor)
}
struct IconButton: View {
    var icon: String
    var help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .foregroundStyle(Palette.muted).help(help).accessibilityLabel(help)
    }
}
struct AppIcon: View {
    @EnvironmentObject var model: StudioModel
    var id: Int64
    var size: CGFloat = 32
    var body: some View {
        Image(nsImage: model.icon(id)).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(
            width: size, height: size)
    }
}

struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct PageHeading: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).fixedSize(
                horizontal: false, vertical: true)
        }
    }
}
