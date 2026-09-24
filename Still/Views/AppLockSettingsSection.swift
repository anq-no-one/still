import SwiftUI

struct AppLockSettingsSection: View {
    let lock: AppLock

    @State private var problem: String?

    var body: some View {
        Section {
            Toggle("Lock Still", isOn: enabled)
            if lock.isEnabled {
                Picker("Require Unlock", selection: timeout) {
                    ForEach(AppLock.timeoutChoices, id: \.self) { seconds in
                        Text(Self.label(for: seconds)).tag(seconds)
                    }
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("App Lock")
        } footer: {
            Text("Your recordings are always encrypted. The lock also hides them behind Face ID, Touch ID, or your device password. Recording keeps going while Still is locked.")
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { lock.isEnabled },
            set: { wantsLock in
                problem = nil
                guard wantsLock else { return lock.disable() }
                Task {
                    switch await lock.enable() {
                    case .success, .cancelled: break
                    case .failed(let message), .unavailable(let message): problem = message
                    }
                }
            }
        )
    }

    private var timeout: Binding<TimeInterval> {
        Binding(get: { lock.timeout }, set: { lock.timeout = $0 })
    }

    private static func label(for seconds: TimeInterval) -> LocalizedStringKey {
        switch seconds {
        case 0: "Immediately"
        case 60: "After 1 Minute"
        case 5 * 60: "After 5 Minutes"
        case 15 * 60: "After 15 Minutes"
        default: "After 1 Hour"
        }
    }
}
