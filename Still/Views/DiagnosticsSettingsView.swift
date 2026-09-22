import SwiftUI

struct DiagnosticsSettingsView: View {
    let diagnostics: Diagnostics

    var body: some View {
        Form {
            Section {
                Toggle("Share Diagnostics", isOn: enabled)
            } footer: {
                Text("If you turn this on, Still reports only the name of what failed, its version, and the kind of device — never audio, transcripts, notes, searches, or keys. You can turn it off again at any time.")
            }

            Section("What a Report Contains") {
                ForEach(DiagnosticEvent.allCases, id: \.self) { event in
                    Text(event.rawValue)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Diagnostics")
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { diagnostics.isEnabled },
            set: { $0 ? diagnostics.enable() : diagnostics.disable() }
        )
    }
}
