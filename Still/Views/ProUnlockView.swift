import SwiftUI

struct ProUnlockView: View {
    let entitlements: Entitlements

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Still Pro", systemImage: "sparkles")
                .font(.title2.bold())

            Text("One purchase unlocks Still Pro on iPhone, iPad, and Mac, and Family Sharing covers your household.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                capability("Live transcript while you record")
                capability("Mac system audio as a separate track")
                capability("Speaker separation, translation, and notes")
                capability("Semantic search, sync, and advanced export")
            }

            statusRow

            HStack {
                Button("Restore purchase") {
                    run { await entitlements.restore() }
                }
                .disabled(isWorking)

                Spacer()

                if entitlements.isPro {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Unlock for $39.99") {
                        run { await entitlements.purchase() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                }
            }
        }
        .padding(28)
        .stillSheetWidth(mac: 400)
    }

    @ViewBuilder
    private var statusRow: some View {
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

    private func capability(_ text: String) -> some View {
        Label(text, systemImage: "checkmark")
            .font(.subheadline)
    }

    private func run(_ work: @escaping () async -> Void) {
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }
}
