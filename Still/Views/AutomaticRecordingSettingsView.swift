#if os(macOS)
import SwiftUI

struct AutomaticRecordingSettingsView: View {
    let automatic: AutomaticRecording

    var body: some View {
        Section {
            Toggle("Record Allowed Apps Automatically", isOn: watching)
            ForEach(automatic.apps) { app in
                Toggle(app.name, isOn: allowed(app))
            }
            if automatic.triggeredBy != nil {
                Button("Throw Away This Recording", role: .destructive) {
                    Task { await automatic.discardAutomaticRecording() }
                }
            }
        } header: {
            Text("Call Apps")
        } footer: {
            Text("Still starts recording when an app you allow here comes forward. Recording always shows in the menu bar and can be stopped or thrown away at once.")
        }
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
