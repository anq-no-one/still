import SwiftUI

struct SyncSettingsView: View {
    let engine: SyncEngine

    var body: some View {
        Form {
            Section {
                Toggle("iCloud Sync", isOn: enabled)
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
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Sync")
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
