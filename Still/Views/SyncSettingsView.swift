import SwiftUI

struct SyncSettingsView: View {
    let engine: SyncEngine
    let entitlements: Entitlements

    var body: some View {
        Form {
            Section {
                Toggle("iCloud Sync", isOn: enabled)
                    .disabled(!entitlements.allows(.synchronization))
            } footer: {
                Text(SyncEngine.whatLeavesTheDevice)
            }

            if engine.isEnabled {
                Section {
                    if let syncedAt = engine.lastSyncedAt {
                        LabeledContent("Last Synced") {
                            Text(syncedAt, format: .dateTime.day().month().hour().minute())
                        }
                    }
                    if let failure = engine.lastFailure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    Button("Sync Now") {
                        Task { await engine.sync() }
                    }
                }
            }

            if !entitlements.allows(.synchronization) {
                Section {
                    Label("Sync is part of Still Pro.", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sync")
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { engine.isEnabled },
            set: { isOn in
                if isOn {
                    engine.enable()
                    Task { await engine.sync() }
                } else {
                    engine.disable()
                }
            }
        )
    }
}
