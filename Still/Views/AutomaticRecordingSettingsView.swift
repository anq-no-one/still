#if os(macOS)
import SwiftUI

struct AutomaticRecordingSettingsView: View {
    let automatic: AutomaticRecording

    var body: some View {
        Section {
            Toggle("Record Calls Automatically", isOn: watching)
            ForEach(automatic.apps) { app in
                Toggle(app.name, isOn: allowed(app))
            }
            if automatic.triggeredBy != nil {
                Button("Throw Away This Recording", role: .destructive) {
                    Task { await automatic.discardAutomaticRecording() }
                }
            }
        } header: {
            Text("Calls")
        } footer: {
            Text("Still starts recording when an app you allow here starts using the microphone, and saves the recording when the call ends. Recording always shows in the menu bar and can be stopped or thrown away at once. For meetings in Safari, use the Still extension below.")
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
