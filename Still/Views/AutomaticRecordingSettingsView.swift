#if os(macOS)
import SwiftUI

struct AutomaticRecordingSettingsView: View {
    let automatic: AutomaticRecording

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Automatic recording", systemImage: "bolt.badge.clock")
                .font(.title2.bold())

            Text("Still starts recording when an app you allow here comes forward. Recording always shows in the menu bar and can be stopped or thrown away at once.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(automatic.apps) { app in
                Toggle(app.name, isOn: allowed(app))
            }

            if automatic.triggeredBy != nil {
                Button("Throw away this recording", role: .destructive) {
                    Task { await automatic.discardAutomaticRecording() }
                }
            }

            HStack {
                Toggle("Watch for allowed apps", isOn: watching)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .stillSheetWidth(mac: 420)
    }

    private func allowed(_ app: CallApp) -> Binding<Bool> {
        Binding(
            get: { app.isAllowed },
            set: { automatic.setAllowed($0, for: app) }
        )
    }

    private var watching: Binding<Bool> {
        Binding(
            get: { automatic.isWatching },
            set: { $0 ? automatic.startWatching() : automatic.stopWatching() }
        )
    }
}
#endif
