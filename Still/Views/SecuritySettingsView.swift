import SwiftUI

struct SecuritySettingsView: View {
    let library: Library
    let lock: AppLock

    @State private var code: RecoveryCode?
    @State private var failure: String?
    @State private var isRevoking = false
    @State private var confirmsRevoke = false

    var body: some View {
        Form {
            AppLockSettingsSection(lock: lock)

            Section {
                if let code {
                    Text(code.formatted)
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                } else {
                    Button("Show Recovery Code", action: showCode)
                }
            } header: {
                Text("Recovery Code")
            } footer: {
                if code == nil {
                    Text("A recovery code lets you open this Library again if this device is lost. Still never stores the code itself.")
                } else {
                    Text("Write this down now. Still shows it once and keeps no readable copy, so without it this Library cannot be opened again.")
                }
            }

            Section {
                Button("Revoke Other Devices…", role: .destructive) { confirmsRevoke = true }
                    .disabled(isRevoking)
            } header: {
                Text("Other Devices")
            } footer: {
                Text("Revoking rotates the key and re-seals everything on this device. A device you no longer have cannot read anything written afterwards.")
            }

            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Keys and Devices")
        .confirmationDialog("Revoke other devices?", isPresented: $confirmsRevoke) {
            Button("Revoke", role: .destructive, action: revoke)
        } message: {
            Text("Other devices stop reading anything this Library writes from now on.")
        }
    }

    private func showCode() {
        do {
            code = try library.makeRecoveryCode()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func revoke() {
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
}
