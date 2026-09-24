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

                DeviceJoiningSections(engine: engine)
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

private struct DeviceJoiningSections: View {
    let engine: SyncEngine

    var body: some View {
        if let invitation = engine.invitation {
            Section {
                Text("Your \(invitation.from?.title ?? String(localized: "other device")) approved this device.")
                LabeledContent("Code") {
                    Text(invitation.code).monospacedDigit()
                }
                Button("Join Library") {
                    Task { await engine.acceptInvitation() }
                }
            } header: {
                Text("Join Your Library")
            } footer: {
                Text("Join only if your other device shows the same code. Recordings on this device stay and move into the joined library.")
            }
        }

        if !engine.joinRequests.isEmpty {
            Section {
                ForEach(engine.joinRequests) { request in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("New \(request.device.kind.title) wants to join")
                            Text(request.code)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Approve") {
                            Task { await engine.approve(request) }
                        }
                    }
                }
            } header: {
                Text("Devices")
            } footer: {
                Text("Approve only if the new device shows the same code. It then receives the projects it chooses to keep.")
            }
        }

        if engine.invitation == nil, !engine.joinTargets.isEmpty {
            Section {
                ForEach(engine.joinTargets) { target in
                    LabeledContent("Approve on your \(target.kind.title)") {
                        Text(target.code).monospacedDigit()
                    }
                }
            } header: {
                Text("Join Your Library")
            } footer: {
                Text("Open Still on that device and approve this one when it shows the same code.")
            }
        }
    }
}
