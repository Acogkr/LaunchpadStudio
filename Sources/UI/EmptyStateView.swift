import SwiftUI

struct EmptyStateView: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        if #available(macOS 14, *) {
            ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
        } else {
            VStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(.secondary)
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(30)
        }
    }
}
