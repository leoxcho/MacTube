#if os(macOS)
import SwiftUI

struct MacYTDLPUpdateSettings: View {
    @State private var updater = MacYTDLPUpdateService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Automatic Updates", isOn: $updater.automaticUpdates)
            LabeledContent("Installed Version", value: updater.installedVersion)
            LabeledContent("Latest Available Version", value: updater.latestVersion ?? "Not checked")
            LabeledContent("Last Checked") {
                if let date = updater.lastChecked { Text(date, format: .dateTime.year().month().day().hour().minute()) }
                else { Text("Never") }
            }
            LabeledContent("Update Status", value: updater.status)
            HStack {
                Button("Check for Updates") { Task { await updater.checkForUpdates() } }
                Button("Update Now") { Task { await updater.updateNow() } }
                Button("Restore Previous Version") { Task { await updater.restorePreviousVersion() } }
                    .disabled(!updater.canRestore)
                if updater.isBusy { ProgressView().controlSize(.small) }
            }.disabled(updater.isBusy)
            if let message = updater.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Text("Official stable macOS releases. Automatic checks run at most once per 24 hours. Activation waits until playback, downloads and resolver jobs are idle. Updates live in MacTube Application Support; the bundled backend remains available.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await updater.refreshInstalledVersion() }
    }
}

/// One low-frequency background task for the process, independent of window
/// count. No redraw timer, decoder or duplicate resolver is introduced.
@MainActor enum MacYTDLPUpdateLifecycle {
    private static var task: Task<Void, Never>?
    static func start() {
        guard task == nil else { return }
        task = Task {
            while !Task.isCancelled {
                await MacYTDLPUpdateService.shared.automaticTick()
                do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
            }
        }
    }
}
#endif
