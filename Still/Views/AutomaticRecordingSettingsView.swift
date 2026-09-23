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
            Text("Still starts recording when an app you allow here joins a call, meaning it uses the microphone and plays sound at the same time. It saves the recording once the app lets go of the microphone. Music and other apps are not recorded. Recording always shows in the menu bar and can be stopped or thrown away at once. For meetings in a browser, use the Still extension below.")
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
