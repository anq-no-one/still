import SwiftUI

struct AccessSettingsView: View {
    let setup: SetupFlow

    var body: some View {
        Form {
            Section {
                row(
                    "Microphone",
                    systemImage: "mic.fill",
                    state: setup.microphone,
                    missing: "Still cannot record until you allow the microphone."
                ) {
                    Task { await setup.requestMicrophone() }
                }
                if setup.asksForSystemAudio {
                    row(
                        "System Audio",
                        systemImage: "person.2.wave.2.fill",
                        state: setup.systemAudio,
                        missing: "Without it, Still records only your side of a call."
                    ) {
                        setup.requestSystemAudio()
                    }
                }
            } header: {
                Text("Required to Record")
            }

            Section {
                row(
                    "Calendar",
                    systemImage: "calendar",
                    state: setup.calendar,
                    missing: "Without it, Still cannot suggest meeting titles or the names of the people expected."
                ) {
                    Task { await setup.requestCalendar() }
                }
            } header: {
                Text("Optional")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Access")
        .task {
            while !Task.isCancelled {
                setup.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func row(
        _ title: LocalizedStringKey,
        systemImage: String,
        state: PermissionState,
        missing: LocalizedStringKey,
        request: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if state != .granted {
                    Text(missing)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            switch state {
            case .granted:
                Label {
                    Text("Allowed")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .labelStyle(.titleAndIcon)
            case .notAsked:
                Button("Allow", action: request)
            case .denied:
                Button("Open Settings", action: request)
            }
        }
    }
}
