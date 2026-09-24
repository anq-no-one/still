#if os(macOS)
import SwiftUI

struct BrowserMeetingSettingsView: View {
    let bridge: BrowserMeetingBridge
    let chromium: ChromiumConnections

    var body: some View {
        Section {
            ForEach(bridge.sites) { site in
                Toggle(site.name, isOn: allowed(site))
            }
        } header: {
            Text("Browser Meetings")
        } footer: {
            Text("The Still extension tells the app when a meeting on one of these sites starts and ends. Still then records only the browser that holds the meeting, so music and videos in other apps stay out. The extension reads no page content, and nothing from your Library ever reaches the browser. Turning the extension off leaves manual recording and allowed call apps working as before.")
        }

        Section {
            ForEach(chromium.connections) { connection in
                Toggle(connection.browser.name, isOn: enabled(connection.browser))
            }
            if let failure = chromium.failure {
                Text(failure)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Chrome, Edge, Brave and Arc")
        } footer: {
            Text("Turn on each browser where you installed the Still extension, so the extension can reach the app. Safari needs no setup here.")
        }
    }

    private func allowed(_ site: MeetingSite) -> Binding<Bool> {
        Binding(
            get: { site.isAllowed },
            set: { bridge.setAllowed($0, for: site) }
        )
    }

    private func enabled(_ browser: WebBrowser) -> Binding<Bool> {
        Binding(
            get: { chromium.connections.first { $0.browser == browser }?.isEnabled ?? false },
            set: { chromium.setEnabled($0, for: browser) }
        )
    }
}
#endif
