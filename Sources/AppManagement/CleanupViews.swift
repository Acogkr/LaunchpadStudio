import AppKit
import SwiftUI

enum CleanupPanel: String, Identifiable {
    case history, leftovers
    var id: String { rawValue }
    var title: String { self == .history ? L("Recent Deletions") : L("Find Leftover Files") }
}

@MainActor final class CleanupController: ObservableObject {
    let model: StudioModel
    let history: RemovalHistory
    @Published var entries: [HistoryEntry] = []
    @Published var groups: [LeftoverGroup] = []
    @Published var notes: [String] = []
    @Published var selection: Set<String> = []
    @Published var unavailable: [String: String] = [:]
    @Published var results: [String: String] = [:]
    @Published var restoredLocations: [String: String] = [:]
    @Published var working = false
    @Published var issue: String?
    @Published var permission: RemovalFailure?
    private var generation = UUID()
    init(model: StudioModel) {
        self.model = model
        history = RemovalHistory(root: model.dataRoot.appendingPathComponent("Removal History"))
    }
    var leftoverScanner: LeftoverScanner {
        let receipts = (try? history.load()) ?? []
        let recorded = receipts.compactMap(\.bundleID)
        var names = model.discovery.names ?? [:]
        for receipt in receipts { if let id = receipt.bundleID, names[id] == nil { names[id] = receipt.appName } }
        return LeftoverScanner(
            scanner: model.protectedRemovalScanner, known: model.discovery.known.union(recorded), names: names)
    }
    func refresh(_ panel: CleanupPanel) {
        guard !working else { return }
        let token = UUID()
        generation = token
        working = true
        issue = nil
        results = [:]
        selection = []
        unavailable = [:]
        permission = nil
        notes = []
        if !model.retryRemovalReceiptSaves() {
            issue = L("Files were moved, but the removal history could not be saved.")
        }
        let history = history
        let restore = TrashRestore(scanner: model.removalScanner)
        let scanner = leftoverScanner
        Task {
            do {
                if panel == .history {
                    let value = try await Task.detached { () -> ([HistoryEntry], [String: String], Int) in
                        let records = try history.read()
                        let entries = try history.entries(from: records.receipts)
                        var unavailable: [String: String] = [:]
                        for entry in entries {
                            do { _ = try restore.validate(entry) } catch {
                                unavailable[entry.id] = error.localizedDescription
                            }
                        }
                        return (entries, unavailable, records.unreadableCount)
                    }.value
                    guard generation == token else { return }
                    entries = value.0
                    unavailable = value.1
                    if value.2 > 0 {
                        issue = L("Some deletion records could not be read. The original records were kept.")
                    }
                } else {
                    let value = try await Task.detached { try scanner.scan() }.value
                    guard generation == token else { return }
                    groups = value.groups
                    notes = value.notes
                }
            } catch { issue = error.localizedDescription }
            working = false
        }
    }
    func restoreSelected() {
        guard !working, !model.busy else { return }
        let chosen = entries.filter { selection.contains($0.id) && unavailable[$0.id] == nil }
        guard !chosen.isEmpty else { return }
        begin(L("Restoring files…"))
        let restore = TrashRestore(scanner: model.removalScanner)
        let history = history
        Task {
            for entry in chosen {
                do {
                    let destination = try await Task.detached { try await restore.restore(entry) }.value
                    do { try history.markRestored(entry, at: destination) } catch {
                        issue = L("Files were restored, but the history could not be saved.")
                    }
                    let status =
                        destination.path == entry.item.originalPath
                        ? L("Restored") : L("Restored to {0}", destination.path)
                    results[entry.id] = status
                    unavailable[entry.id] = status
                    restoredLocations[entry.id] = destination.path
                    selection.remove(entry.id)
                } catch {
                    results[entry.id] = error.localizedDescription
                    let failure = RemovalFailure(
                        error, url: URL(fileURLWithPath: entry.item.originalPath), kind: entry.item.kind ?? .appData)
                    permission = failure
                    if [.cancelled, .automation].contains(failure.recovery) { break }
                }
            }
            finish()
        }
    }
    func removeSelected() {
        guard !working, !model.busy, !selection.isEmpty else { return }
        begin(L("Moving to Trash…"))
        let selected = selection
        let scanner = leftoverScanner
        let history = history
        let groups = groups
        Task {
            for group in groups where group.files.contains(where: { selected.contains($0.id) }) {
                do {
                    let receipt = try await Task.detached {
                        try await scanner.remove(
                            group, selected: selected.intersection(Set(group.files.map(\.id))), history: history)
                    }.value
                    showRemovalResult(receipt)
                    if let failure = receipt.items.compactMap(\.failure).first {
                        permission = failure
                        if [.cancelled, .automation].contains(failure.recovery) { break }
                    }
                } catch {
                    if let interrupted = error as? RemovalHistoryWriteError {
                        model.recordRemovalReceipt(interrupted.receipt)
                        showRemovalResult(interrupted.receipt)
                    }
                    issue = error.localizedDescription
                    break
                }
            }
            finish()
        }
    }
    private func showRemovalResult(_ receipt: RemovalReceipt) {
        for item in receipt.items {
            results[item.id] = item.error ?? L("Moved to Trash")
            if item.trashPath != nil {
                unavailable[item.id] = L("Moved to Trash")
                selection.remove(item.id)
            }
        }
    }
    private func begin(_ text: String) {
        working = true
        model.busyText = text
        model.busy = true
        issue = nil
        permission = nil
    }
    private func finish() {
        working = false
        model.busy = false
        model.applicationMonitor?.refresh()
        model.reconcileLaunchpadCatalog()
    }
}

struct CleanupSheet: View {
    let panel: CleanupPanel
    @ObservedObject var model: StudioModel
    @StateObject private var controller: CleanupController
    init(panel: CleanupPanel, model: StudioModel) {
        self.panel = panel
        self.model = model
        _controller = StateObject(wrappedValue: CleanupController(model: model))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(panel.title).font(.system(size: 17, weight: .semibold))
                Text(
                    panel == .history
                        ? L("Restore files before Trash is emptied. Existing files are never replaced.")
                        : L("Checks apps previously seen on this Mac. Review and select the files to remove.")
                )
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            if controller.working && !model.busy {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(L("Finding related files…")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if panel == .history ? controller.entries.isEmpty : controller.groups.isEmpty {
                Text(panel == .history ? L("No recent deletions") : L("No leftover files found"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if panel == .history {
                            ForEach(controller.entries) { entry in
                                fileRow(
                                    id: entry.id,
                                    title: URL(fileURLWithPath: entry.item.originalPath).lastPathComponent,
                                    path: entry.item.originalPath,
                                    detail: entry.receipt.appName + " · " + L10n.date(entry.receipt.date),
                                    reveal: controller.restoredLocations[entry.id] ?? entry.item.restoredPath
                                        ?? entry.item.trashPath)
                            }
                        } else {
                            ForEach(controller.groups) { group in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.name ?? group.bundleID).font(.system(size: 12, weight: .medium))
                                    if group.name != nil && group.name != group.bundleID {
                                        Text(group.bundleID).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }.padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 6)
                                ForEach(group.files) { file in
                                    fileRow(
                                        id: file.id, title: file.kind.title, path: file.id, detail: file.sizeLabel,
                                        reveal: file.id)
                                }
                            }
                        }
                    }
                }.overlay(Rectangle().strokeBorder(Palette.line, lineWidth: 0.5))
            }
            if !controller.notes.isEmpty {
                DisclosureGroup(L("Search notes ({0})", controller.notes.count)) {
                    ScrollView {
                        Text(controller.notes.joined(separator: "\n")).frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }.frame(maxHeight: 65)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let issue = controller.issue {
                Text(issue).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let failure = controller.permission, failure.recovery != .other, failure.recovery != .cancelled {
                Text(failure.guidance).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
            }
            if let url = controller.permission?.settingsURL {
                Button(L("Open Finder Permissions…")) {
                    if !NSWorkspace.shared.open(url) {
                        controller.issue = L("Could not open System Settings. Try again.")
                    }
                }.controlSize(.small)
            }
            Divider()
            HStack {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text(model.busyText).font(.system(size: 12))
                } else {
                    Button(L("Refresh")) { controller.refresh(panel) }.disabled(controller.working)
                    Text(L("Selected: {0}", controller.selection.count)).font(.system(size: 11)).foregroundStyle(
                        .secondary)
                }
                Spacer()
                Button(L("Close")) { model.cleanupPanel = nil }.keyboardShortcut(.cancelAction).disabled(model.busy)
                if panel == .history {
                    Button(L("Restore Selected")) { controller.restoreSelected() }.disabled(
                        controller.working || controller.selection.isEmpty)
                } else {
                    Button(L("Move to Trash"), role: .destructive) { controller.removeSelected() }.disabled(
                        controller.working || controller.selection.isEmpty)
                }
            }
        }.padding(24).frame(width: 650, height: 550).background(Palette.chrome)
            .interactiveDismissDisabled(model.busy)
            .onAppear { controller.refresh(panel) }
    }
    func fileRow(id: String, title: String, path: String, detail: String, reveal: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { controller.selection.contains(id) },
                    set: {
                        if $0 { controller.selection.insert(id) } else { controller.selection.remove(id) }
                    })
            ).toggleStyle(.checkbox).labelsHidden().disabled(controller.working || controller.unavailable[id] != nil)
                .accessibilityLabel(L("Select {0}", title))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text((path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(path)
                if let status = controller.results[id] ?? controller.unavailable[id] {
                    Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).help(status)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let reveal {
                IconButton(icon: "folder", help: L("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: reveal)])
                }
                .disabled(model.busy || !FileManager.default.fileExists(atPath: reveal))
            }
        }.padding(12)
            .overlay(alignment: .bottom) { Divider() }
    }
}
