import SwiftUI

struct SyncSettingsView: View {
    let engine: SyncEngine
    let entitlements: Entitlements

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("iCloud sync", systemImage: "arrow.triangle.2.circlepath")
                .font(.title2.bold())

            Text(SyncEngine.whatLeavesTheDevice)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !entitlements.allows(.synchronization) {
                Label("Sync is part of Still Pro.", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
            }

            if let failure = engine.lastFailure, engine.isEnabled {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            if let syncedAt = engine.lastSyncedAt {
                Text("Last synced \(syncedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Button("Close", role: .cancel) { dismiss() }

                Spacer()

                if engine.isEnabled {
                    Button("Turn off sync", role: .destructive, action: engine.disable)
                } else {
                    Button("Turn on sync") {
                        engine.enable()
                        Task { await engine.sync() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!entitlements.allows(.synchronization))
                }
            }
        }
        .padding(28)
        .stillSheetWidth(mac: 420)
    }
}
