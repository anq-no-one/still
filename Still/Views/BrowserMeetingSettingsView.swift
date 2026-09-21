#if os(macOS)
import SwiftUI

struct BrowserMeetingSettingsView: View {
    let bridge: BrowserMeetingBridge

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Browser meetings", systemImage: "safari")
                .font(.title2.bold())

            Text("The Still extension tells the app when a meeting on one of these sites starts and ends. It reads no page content, and nothing from your Library ever reaches the browser.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(bridge.sites) { site in
                Toggle(site.name, isOn: allowed(site))
            }

            Text("Turning the extension off in Safari leaves manual recording and allowed call apps working exactly as before.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(minWidth: 420, idealWidth: 480)
    }

    private func allowed(_ site: MeetingSite) -> Binding<Bool> {
        Binding(
            get: { site.isAllowed },
            set: { bridge.setAllowed($0, for: site) }
        )
    }
}
#endif
