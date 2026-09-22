import SwiftUI

struct ProUnlockView: View {
    let entitlements: Entitlements

    @State private var isWorking = false

    var body: some View {
        Form {
            Section {
                Label("Live transcript while you record", systemImage: "text.bubble")
                Label("Mac system audio as a separate track", systemImage: "speaker.wave.2")
                Label("Speakers, translation, and notes", systemImage: "person.2")
                Label("Meaning search, sync, and advanced export", systemImage: "magnifyingglass")
            } footer: {
                Text("One purchase unlocks Still Pro on iPhone, iPad, and Mac, and Family Sharing covers your household.")
            }

            Section {
                status
                if !entitlements.isPro {
                    Button("Unlock for $39.99") {
                        run { await entitlements.purchase() }
                    }
                    .disabled(isWorking)
                }
                Button("Restore Purchase") {
                    run { await entitlements.restore() }
                }
                .disabled(isWorking)
            }
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Still Pro")
    }

    @ViewBuilder
    private var status: some View {
        switch entitlements.status {
        case .pro:
            Label("Still Pro is active on this device", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .pending:
            Label("Waiting for approval. Still unlocks Pro as soon as it is approved.", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .free where entitlements.storeUnavailable:
            Label("The App Store is unreachable. Recording keeps working.", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
        case .free:
            EmptyView()
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }
}
