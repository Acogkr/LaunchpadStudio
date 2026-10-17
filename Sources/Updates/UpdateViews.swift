import SwiftUI

struct UpdateButton: View {
    @ObservedObject var updates: UpdateChecker
    @State private var openFailed = false
    var body: some View {
        if let release = updates.availableRelease {
            Button { openFailed = !updates.openRelease() } label: {
                Label(L("Update"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent).tint(.blue).controlSize(.small).fixedSize()
            .help(L("Version {0} is available.", release.displayVersion))
            .accessibilityLabel(L("Update Available ({0})…", release.displayVersion))
            .alert(L("Unable to Complete"), isPresented: $openFailed) {
                Button(L("OK"), role: .cancel) {}
            } message: { Text(UpdateCheckError.openFailed.message) }
        }
    }
}
