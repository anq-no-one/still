import SwiftUI

struct SecuritySettingsView: View {
    let library: Library

    @Environment(\.dismiss) private var dismiss
    @State private var code: RecoveryCode?
    @State private var failure: String?
    @State private var isRevoking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Keys and devices", systemImage: "key")
                .font(.title2.bold())

            if let code {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Write this down now. Still shows it once and keeps no readable copy, so without it this Library cannot be opened again.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(code.formatted)
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                }
            } else {
                Text("A recovery code lets you open this Library again if this device is lost. Still never stores the code itself.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            Divider()

            Text("Revoking rotates the key and re-seals everything on this device. A device you no longer have cannot read anything written afterwards.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Close", role: .cancel) { dismiss() }

                Spacer()

                Button("Revoke other devices", role: .destructive) {
                    isRevoking = true
                    Task {
                        do {
                            try await library.revokeOtherDevices()
                            failure = nil
                        } catch {
                            failure = error.localizedDescription
                        }
                        isRevoking = false
                    }
                }
                .disabled(isRevoking)

                Button(code == nil ? "Show recovery code" : "Done") {
                    if code == nil {
                        do {
                            code = try library.makeRecoveryCode()
                        } catch {
                            failure = error.localizedDescription
                        }
                    } else {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .stillSheetWidth(mac: 440)
    }
}
