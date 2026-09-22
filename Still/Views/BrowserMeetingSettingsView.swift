#if os(macOS)
import SwiftUI

struct BrowserMeetingSettingsView: View {
    let bridge: BrowserMeetingBridge

    var body: some View {
        Section {
            ForEach(bridge.sites) { site in
                Toggle(site.name, isOn: allowed(site))
            }
        } header: {
            Text("Browser Meetings")
        } footer: {
            Text("The Still extension for Safari tells the app when a meeting on one of these sites starts and ends. It reads no page content, and nothing from your Library ever reaches the browser. Turning the extension off leaves manual recording and allowed call apps working as before.")
        }
    }

    private func allowed(_ site: MeetingSite) -> Binding<Bool> {
        Binding(
            get: { site.isAllowed },
            set: { bridge.setAllowed($0, for: site) }
        )
    }
}
#endif
