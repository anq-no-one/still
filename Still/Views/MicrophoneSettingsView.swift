#if os(macOS)
import SwiftUI

struct MicrophoneSettingsView: View {
    let microphones: MicrophoneChoice

    var body: some View {
        Section {
            Picker("Microphone", selection: choice) {
                Text(systemDefaultTitle).tag(String?.none)
                ForEach(microphones.devices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
                if let missing = microphones.unavailableChoice {
                    Text("\(missing.name) (Unavailable)").tag(Optional(missing.uid))
                }
            }
            LabeledContent("In Use", value: microphones.active?.name ?? String(localized: "No Microphone"))
            if let notice = microphones.fallbackNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.attention)
            }
            levelTestRow
            if let reason = microphones.levelTestUnavailableReason {
                Text(reason)
                    .foregroundStyle(.secondary)
            } else if case .failed(let message) = microphones.levelTest {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Microphone")
        } footer: {
            Text("Still follows the input chosen in System Settings unless you pick one here. If the microphone you pick is unplugged, Still uses the system input and says so here and in the menu bar. The test shows the input level and records nothing.")
        }
    }

    private var levelTestRow: some View {
        HStack(spacing: 12) {
            Button(microphones.isTestingLevel ? "Stop Test" : "Test Microphone", action: toggleLevelTest)
                .disabled(!microphones.isTestingLevel && !microphones.canTestLevel)
            Gauge(value: level) {
                Text("Input Level")
            }
            .gaugeStyle(.linearCapacity)
            .tint(.green)
            .accessibilityLabel("Input Level")
            .accessibilityValue(levelDescription)
        }
        .onDisappear { microphones.stopLevelTest() }
    }

    private var level: Double {
        if case .listening(let level) = microphones.levelTest { level } else { 0 }
    }

    private var levelDescription: Text {
        guard microphones.isTestingLevel else { return Text("Not testing") }
        return Text(level, format: .percent.precision(.fractionLength(0)))
    }

    private var systemDefaultTitle: String {
        guard let systemDefault = microphones.systemDefault else { return String(localized: "System Default") }
        return String(localized: "System Default (\(systemDefault.name))")
    }

    private var choice: Binding<String?> {
        Binding(
            get: { microphones.chosen?.uid },
            set: { uid in
                guard let uid else { return microphones.choose(nil) }
                guard let device = microphones.devices.first(where: { $0.uid == uid }) else { return }
                microphones.choose(device)
            }
        )
    }

    private func toggleLevelTest() {
        if microphones.isTestingLevel {
            microphones.stopLevelTest()
        } else {
            microphones.startLevelTest()
        }
    }
}
#endif
