import AppKit
import SwiftUI

struct NewAppsToast: View {
    @EnvironmentObject var model: StudioModel
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.badge.plus").foregroundStyle(.secondary)
            Text(L("New apps to arrange: {0}", model.newApplications.count)).font(.system(size: 12))
            Button(L("Review Apps")) { model.reviewNewApplications() }.buttonStyle(.bordered).controlSize(.small)
            IconButton(icon: "xmark", help: L("Dismiss")) {
                model.newAppToast = false
                model.waitingForNewAppRegistration = false
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
    }
}

struct RemovalSheet: View {
    @EnvironmentObject var model: StudioModel
    @State private var running = false
    @State private var settingsOpenFailed = false
    var completedIDs: Set<String> { Set(model.removalCompleted.map(\.originalPath)) }
    var selectedSize: String {
        guard let plan = model.removalPlan else { return "" }
        let selected = plan.candidates.filter {
            model.removalSelection.contains($0.id) && !completedIDs.contains($0.id)
        }
        let bytes = selected.compactMap(\.bytes).reduce(0, +)
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return selected.contains(where: { $0.bytes == nil }) ? L("At least {0}", size) : size
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 13) {
                if let app = model.removalTarget {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().aspectRatio(
                        contentMode: .fit
                    ).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.removalReceipt == nil ? L("Remove {0}", app.name) : L("Removal Results")).font(
                            .system(size: 17, weight: .semibold))
                        Text(
                            model.removalReceipt != nil
                                ? L(
                                    "Restore removed files from Recent Deletions in the app menu, before Trash is emptied."
                                )
                                : (completedIDs.contains(app.path)
                                    ? L("The app is already in Trash. Review the remaining files.")
                                    : L("Choose the files to move to Trash."))
                        ).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            Divider()
            if let receipt = model.removalReceipt {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(receipt.items) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.trashPath == nil ? "exclamationmark.circle" : "checkmark.circle")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(URL(fileURLWithPath: item.originalPath).lastPathComponent).font(
                                        .system(size: 12, weight: .medium)
                                    ).lineLimit(2).help(item.originalPath)
                                    Text(item.error ?? L("Moved to Trash")).font(.system(size: 11)).foregroundStyle(
                                        .secondary
                                    ).lineLimit(2).help(item.error ?? L("Moved to Trash")).textSelection(.enabled)
                                }
                                Spacer()
                                if let path = item.trashPath {
                                    Button(L("Show")) {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                    }.controlSize(.small)
                                }
                            }
                        }
                    }.padding(12)
                }.frame(maxHeight: .infinity)
            } else if model.removalScanning {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(L("Finding related files…")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let plan = model.removalPlan {
                if running {
                    HStack {
                        Text(L("Quit the app before removing it.")).font(.system(size: 12))
                        Spacer()
                        Button(L("Quit App")) { model.quitRemovalTarget() }
                    }
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(plan.candidates.filter { !completedIDs.contains($0.id) }) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { model.removalSelection.contains(item.id) },
                                        set: {
                                            if $0 {
                                                model.removalSelection.insert(item.id)
                                            } else {
                                                model.removalSelection.remove(item.id)
                                            }
                                        })
                                ).toggleStyle(.checkbox).labelsHidden().disabled(
                                    item.kind == .application || model.busy
                                )
                                .accessibilityLabel(L("Select {0}", item.url.lastPathComponent))
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 7) {
                                        Text(item.kind.title).font(.system(size: 12, weight: .medium))
                                        if item.needsReview {
                                            Text(L("Review contents")).font(.system(size: 10)).foregroundStyle(
                                                .secondary)
                                        }
                                    }
                                    Text((item.id as NSString).abbreviatingWithTildeInPath).font(.system(size: 11))
                                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(item.id)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(item.sizeLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .monospacedDigit()
                                IconButton(icon: "folder", help: L("Show in Finder")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                }
                            }.padding(12)
                            Divider()
                        }
                    }
                }.overlay(Rectangle().strokeBorder(Palette.line, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("If permission is needed, a macOS approval dialog will appear."))
                    Text(L("App data may contain your work. It is not selected automatically."))
                    Text(L("Shared folders are excluded. Layout backups do not restore deleted files."))
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Spacer()
            }
            if let plan = model.removalPlan, !plan.notes.isEmpty, !model.removalScanning {
                DisclosureGroup(L("Search notes ({0})", plan.notes.count)) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(plan.notes, id: \.self) {
                                Text($0).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 75)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error = model.removalError {
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let issue = model.removalAccessIssue, issue.recovery != .other, issue.recovery != .cancelled,
                model.removalReceipt?.hasFailures == true || model.removalError != nil
            {
                VStack(alignment: .leading, spacing: 8) {
                    Text(issue.guidance).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    if let url = issue.settingsURL {
                        Button(issue.settingsTitle) {
                            settingsOpenFailed = !NSWorkspace.shared.open(url)
                            if !settingsOpenFailed {
                                NSRunningApplication.runningApplications(
                                    withBundleIdentifier: "com.apple.systempreferences"
                                ).first?.activate(options: [.activateAllWindows])
                            }
                        }.buttonStyle(.bordered).controlSize(.small)
                        if settingsOpenFailed {
                            Text(L("Could not open System Settings. Try again.")).font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text(L("Moving to Trash…")).font(.system(size: 12))
                } else if model.removalPlan != nil && model.removalReceipt == nil {
                    Text(selectedSize).font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(L("Scan Again")) { model.scanRemoval() }.buttonStyle(.link)
                } else if model.removalError != nil && model.removalReceipt == nil {
                    Button(L("Scan Again")) { model.scanRemoval() }
                } else if model.removalReceipt?.hasFailures == true {
                    Button(L("Scan Again")) { model.scanRemoval() }.buttonStyle(.link)
                }
                Spacer()
                Button(model.removalReceipt == nil ? L("Cancel") : L("Done")) { model.closeRemoval() }.keyboardShortcut(
                    .cancelAction
                ).disabled(model.busy)
                if model.removalReceipt?.hasFailures == true {
                    if let issue = model.removalAccessIssue, issue.permitsFinderRetry {
                        Button(issue.finderActionTitle) { model.removeSelectedFiles(usingFinder: true) }.disabled(
                            model.busy || running)
                    } else {
                        Button(L("Retry Remaining")) { model.removeSelectedFiles() }.disabled(model.busy || running)
                    }
                }
                if model.removalReceipt == nil {
                    Button(L("Move to Trash"), role: .destructive) { model.removeSelectedFiles() }
                        .disabled(
                            model.removalPlan == nil || model.removalScanning || model.busy || running
                                || model.removalError != nil || model.removalSelection.subtracting(completedIDs).isEmpty
                        )
                }
            }
        }.padding(24).frame(width: 650, height: 550)
            .interactiveDismissDisabled(model.busy)
            .task {
                while !Task.isCancelled {
                    running = model.removalTarget.map(ApplicationRemoval.isRunning) ?? false
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
}
