import SwiftUI

struct DiagnosticsSettingsView: View {
    let diagnostics: Diagnostics

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Diagnostics", systemImage: "stethoscope")
                .font(.title2.bold())

            Text("Diagnostics is off. If you turn it on, Still reports only the name of what failed, its version, and the kind of device — never audio, transcripts, notes, searches, or keys. You can turn it off again at any time.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Send diagnostics", isOn: enabled)

            VStack(alignment: .leading, spacing: 4) {
                Text("What a report contains")
                    .font(.headline)

                ForEach(DiagnosticEvent.allCases, id: \.self) { event in
                    Text("• \(event.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(minWidth: 420, idealWidth: 480)
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { diagnostics.isEnabled },
            set: { $0 ? diagnostics.enable() : diagnostics.disable() }
        )
    }
}
