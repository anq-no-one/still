#if os(macOS)
import Foundation
import Observation

struct ChosenMicrophone: Codable, Equatable, Sendable {
    let uid: String
    let name: String
}

protocol MicrophoneChoiceStore: Sendable {
    var chosen: ChosenMicrophone? { get }
    func setChosen(_ chosen: ChosenMicrophone?)
}

enum LevelTest: Equatable {
    case stopped
    case listening(level: Double)
    case failed(String)
}

@MainActor
@Observable
final class MicrophoneChoice {
    private let source: AudioInputDevices
    private let store: MicrophoneChoiceStore
    private let meter: MicrophoneLevelMeter
    private let isRecording: @MainActor () -> Bool

    private(set) var devices: [AudioInputDevice] = []
    private(set) var systemDefault: AudioInputDevice?
    private(set) var chosen: ChosenMicrophone?
    private(set) var levelTest = LevelTest.stopped

    init(
        source: AudioInputDevices,
        store: MicrophoneChoiceStore,
        meter: MicrophoneLevelMeter,
        isRecording: @escaping @MainActor () -> Bool
    ) {
        self.source = source
        self.store = store
        self.meter = meter
        self.isRecording = isRecording
        chosen = store.chosen
        refresh()
        source.observe { [weak self] in self?.refresh() }
    }

    var active: AudioInputDevice? {
        chosenDevice ?? systemDefault
    }

    var captureDeviceUID: String? {
        chosenDevice?.uid
    }

    var unavailableChoice: ChosenMicrophone? {
        chosenDevice == nil ? chosen : nil
    }

    var fallbackNotice: String? {
        guard let missing = unavailableChoice else { return nil }
        guard let systemDefault else {
            return String(localized: "\(missing.name) is unavailable and no other microphone is connected.")
        }
        return String(localized: "Using \(systemDefault.name) because \(missing.name) is unavailable.")
    }

    var levelTestUnavailableReason: String? {
        if isRecording() { return String(localized: "Stop the recording to test the microphone.") }
        if active == nil { return String(localized: "Connect a microphone to test it.") }
        return nil
    }

    var canTestLevel: Bool {
        levelTestUnavailableReason == nil
    }

    var isTestingLevel: Bool {
        if case .listening = levelTest { true } else { false }
    }

    func choose(_ device: AudioInputDevice?) {
        chosen = device.map { ChosenMicrophone(uid: $0.uid, name: $0.name) }
        store.setChosen(chosen)
        restartLevelTest()
    }

    func startLevelTest() {
        guard !isTestingLevel, canTestLevel else { return }

        do {
            try meter.start { [weak self] level in self?.heard(level) }
            levelTest = .listening(level: 0)
        } catch {
            levelTest = .failed(error.localizedDescription)
        }
    }

    func stopLevelTest() {
        meter.stop()
        levelTest = .stopped
    }

    private var chosenDevice: AudioInputDevice? {
        guard let chosen else { return nil }
        return devices.first { $0.uid == chosen.uid }
    }

    private func heard(_ level: Double) {
        guard isTestingLevel else { return }
        guard !isRecording() else {
            stopLevelTest()
            return
        }
        levelTest = .listening(level: level)
    }

    private func refresh() {
        let previous = active
        devices = source.devices
        systemDefault = source.systemDefault
        if active != previous {
            restartLevelTest()
        }
    }

    private func restartLevelTest() {
        guard isTestingLevel else { return }
        stopLevelTest()
        startLevelTest()
    }
}

struct UserDefaultsMicrophoneChoiceStore: MicrophoneChoiceStore, @unchecked Sendable {
    private let key = "still.microphone.chosen"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var chosen: ChosenMicrophone? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ChosenMicrophone.self, from: $0) }
    }

    func setChosen(_ chosen: ChosenMicrophone?) {
        guard let chosen, let data = try? JSONEncoder().encode(chosen) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
#endif
