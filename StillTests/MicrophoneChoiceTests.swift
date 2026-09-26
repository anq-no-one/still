import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct MicrophoneChoiceTests {
    private let builtIn = AudioInputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private let headset = AudioInputDevice(uid: "USB-Headset-1", name: "USB Headset")
    private let studio = AudioInputDevice(uid: "Studio-2", name: "Studio Mic")

    @Test
    func followsTheSystemDefaultUntilTheUserChooses() {
        let source = FakeAudioInputDevices(devices: [builtIn, headset], systemDefault: builtIn)
        let choice = make(source: source)

        #expect(choice.chosen == nil)
        #expect(choice.active == builtIn)
        #expect(choice.captureDeviceUID == nil)
        #expect(choice.fallbackNotice == nil)
    }

    @Test
    func aSystemDefaultChangeUpdatesTheActiveDevice() {
        let source = FakeAudioInputDevices(devices: [builtIn, headset], systemDefault: builtIn)
        let choice = make(source: source)

        source.systemDefault = headset
        source.changed()

        #expect(choice.systemDefault == headset)
        #expect(choice.active == headset)
        #expect(choice.captureDeviceUID == nil)
    }

    @Test
    func aChosenDeviceIsCapturedAndRemembered() {
        let source = FakeAudioInputDevices(devices: [builtIn, headset], systemDefault: builtIn)
        let store = MemoryMicrophoneChoiceStore()
        let choice = make(source: source, store: store)

        choice.choose(headset)
        let relaunched = make(source: source, store: store)

        #expect(choice.active == headset)
        #expect(choice.captureDeviceUID == headset.uid)
        #expect(relaunched.active == headset)
        #expect(relaunched.captureDeviceUID == headset.uid)
    }

    @Test
    func aChosenDeviceOutlivesASystemDefaultChange() {
        let source = FakeAudioInputDevices(devices: [builtIn, headset, studio], systemDefault: builtIn)
        let choice = make(source: source)
        choice.choose(headset)

        source.systemDefault = studio
        source.changed()

        #expect(choice.active == headset)
        #expect(choice.systemDefault == studio)
    }

    @Test
    func unpluggingTheChosenDeviceFallsBackAndSaysSo() {
        let source = FakeAudioInputDevices(devices: [builtIn, headset], systemDefault: builtIn)
        let choice = make(source: source)
        choice.choose(headset)

        source.devices = [builtIn]
        source.changed()

        #expect(choice.active == builtIn)
        #expect(choice.captureDeviceUID == nil)
        #expect(choice.unavailableChoice == ChosenMicrophone(uid: headset.uid, name: headset.name))
        #expect(choice.fallbackNotice == "Using MacBook Pro Microphone because USB Headset is unavailable.")
    }

    @Test
    func aChosenDeviceMissingAtLaunchIsReportedBeforeRecording() {
        let store = MemoryMicrophoneChoiceStore()
        store.setChosen(ChosenMicrophone(uid: headset.uid, name: headset.name))

        let choice = make(source: FakeAudioInputDevices(devices: [builtIn], systemDefault: builtIn), store: store)

        #expect(choice.active == builtIn)
        #expect(choice.fallbackNotice == "Using MacBook Pro Microphone because USB Headset is unavailable.")
    }

    @Test
    func pluggingTheChosenDeviceBackRestoresIt() {
        let source = FakeAudioInputDevices(devices: [builtIn, headset], systemDefault: builtIn)
        let choice = make(source: source)
        choice.choose(headset)
        source.devices = [builtIn]
        source.changed()

        source.devices = [builtIn, headset]
        source.changed()

        #expect(choice.active == headset)
        #expect(choice.captureDeviceUID == headset.uid)
        #expect(choice.fallbackNotice == nil)
    }

    @Test
    func noMicrophoneAtAllIsReported() {
        let source = FakeAudioInputDevices(devices: [headset], systemDefault: headset)
        let choice = make(source: source)
        choice.choose(headset)

        source.devices = []
        source.systemDefault = nil
        source.changed()

        #expect(choice.active == nil)
        #expect(choice.fallbackNotice == "USB Headset is unavailable and no other microphone is connected.")
        #expect(!choice.canTestLevel)
    }

    @Test
    func goingBackToTheSystemDefaultForgetsTheChoice() {
        let source = FakeAudioInputDevices(devices: [builtIn, headset], systemDefault: builtIn)
        let store = MemoryMicrophoneChoiceStore()
        let choice = make(source: source, store: store)
        choice.choose(headset)

        choice.choose(nil)

        #expect(choice.active == builtIn)
        #expect(store.chosen == nil)
    }

    @Test
    func theLevelTestShowsWhatTheMeterHears() async {
        let meter = FakeLevelMeter()
        let choice = make(meter: meter)

        choice.startLevelTest()
        await waitForMeter(meter)
        meter.hear(0.6)

        #expect(choice.levelTest == .listening(level: 0.6))

        choice.stopLevelTest()

        #expect(choice.levelTest == .stopped)
        #expect(!meter.isRunning)
    }

    @Test
    func theLevelTestRefusesWhileRecording() async throws {
        let (coordinator, library) = try await makeCoordinator()
        let meter = FakeLevelMeter()
        let choice = make(meter: meter, isRecording: { coordinator.isCapturing })
        await coordinator.start()

        choice.startLevelTest()

        #expect(coordinator.isRecording)
        #expect(!choice.canTestLevel)
        #expect(choice.levelTestUnavailableReason != nil)
        #expect(choice.levelTest == .stopped)
        #expect(meter.starts == 0)

        await coordinator.cancel()
        #expect(library.recordings.isEmpty)
    }

    @Test
    func theLevelTestStopsWhenARecordingStarts() async {
        let meter = FakeLevelMeter()
        let recording = Flag()
        let choice = make(meter: meter, isRecording: { recording.isRaised })
        choice.startLevelTest()
        await waitForMeter(meter)

        recording.raise()
        meter.hear(0.4)

        #expect(choice.levelTest == .stopped)
        #expect(!meter.isRunning)
    }

    @Test
    func choosingAnotherDeviceRestartsARunningLevelTest() async {
        let meter = FakeLevelMeter()
        let choice = make(meter: meter)
        choice.startLevelTest()
        await waitForMeter(meter)

        choice.choose(headset)
        await waitForMeter(meter, starts: 2)

        #expect(meter.starts == 2)
        #expect(meter.isRunning)
        #expect(choice.isTestingLevel)
    }

    @Test
    func unpluggingTheTestedDeviceRestartsTheLevelTestOnTheFallback() async {
        let source = FakeAudioInputDevices(devices: [builtIn, headset], systemDefault: builtIn)
        let meter = FakeLevelMeter()
        let choice = make(source: source, meter: meter)
        choice.choose(headset)
        choice.startLevelTest()
        await waitForMeter(meter)

        source.devices = [builtIn]
        source.changed()
        await waitForMeter(meter, starts: 2)

        #expect(meter.starts == 2)
        #expect(choice.isTestingLevel)
        #expect(choice.active == builtIn)
    }

    @Test
    func aMeterThatCannotStartReportsWhy() async {
        let meter = FakeLevelMeter()
        meter.failure = CaptureError.inputUnavailable
        let choice = make(meter: meter)

        choice.startLevelTest()
        for _ in 0..<200 {
            if case .failed = choice.levelTest { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(choice.levelTest == .failed(CaptureError.inputUnavailable.localizedDescription))
    }

    @Test
    func theLevelTestHearsTheMicrophoneWithoutSavingARecording() async throws {
        let fixture = try #require(Bundle.main.url(forResource: "meeting", withExtension: "fixture.caf"))
        let microphone = MicrophoneInput(fixture: fixture)
        let (coordinator, library) = try await makeCoordinator()
        let choice = make(meter: InputLevelMeter(input: microphone), isRecording: { coordinator.isCapturing })

        choice.startLevelTest()
        for _ in 0..<300 where heardLevel(choice) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(heardLevel(choice) > 0)
        #expect(microphone.isRunning)

        choice.stopLevelTest()

        #expect(!microphone.isRunning)
        #expect(coordinator.phase == .idle)
        #expect(library.recordings.isEmpty)
    }

    @Test
    func coreAudioListsTheSystemDefaultAmongItsInputs() {
        let source = CoreAudioInputDevices()

        let devices = source.devices
        if let systemDefault = source.systemDefault {
            #expect(devices.contains(systemDefault))
            #expect(CoreAudioInputDevices.deviceID(forUID: systemDefault.uid) != nil)
        }
        #expect(Set(devices.map(\.uid)).count == devices.count)
    }

    @Test
    func silenceReadsAsNoLevelAndFullScaleAsFull() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let silence = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        silence.frameLength = 160
        silence.floatChannelData?[0].update(repeating: 0, count: 160)
        let loud = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        loud.frameLength = 160
        loud.floatChannelData?[0].update(repeating: 1, count: 160)

        #expect(InputLevel.of(silence) == 0)
        #expect(InputLevel.of(loud) == 1)
    }

    private func heardLevel(_ choice: MicrophoneChoice) -> Double {
        if case .listening(let level) = choice.levelTest { level } else { 0 }
    }

    private func waitForMeter(_ meter: FakeLevelMeter, starts: Int = 1) async {
        for _ in 0..<200 where meter.starts < starts {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func make(
        source: FakeAudioInputDevices? = nil,
        store: MemoryMicrophoneChoiceStore = MemoryMicrophoneChoiceStore(),
        meter: MicrophoneLevelMeter = FakeLevelMeter(),
        isRecording: @escaping @MainActor () -> Bool = { false }
    ) -> MicrophoneChoice {
        MicrophoneChoice(
            source: source ?? FakeAudioInputDevices(devices: [builtIn, headset], systemDefault: builtIn),
            store: store,
            meter: meter,
            isRecording: isRecording
        )
    }

    private func makeCoordinator() async throws -> (RecordingCoordinator, Library) {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let audioRoot = try Scratch().directory
        let library = Library(
            keyRing: LibraryKeyRing(source: FakeDeviceKeySource()),
            services: LibraryServices(
                audioRoot: audioRoot,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { key in
                    MainActor.assumeIsolated { WritingRecorder(root: audioRoot, cipher: LibraryCipher(key: key)) }
                },
                makeEmbeddingEngine: { nil }
            )
        )
        await library.unlock()

        let coordinator = RecordingCoordinator(
            library: library,
            entitlements: Entitlements(source: FakeEntitlementSource(), cache: MemoryEntitlementCache()),
            makeSession: { FakeTranscriptionSession() },
            makeFinalTranscription: { FinalTranscription(transcriber: StubOfflineTranscriber(), windowSeconds: 3_600) }
        )
        return (coordinator, library)
    }
}

@MainActor
final class FakeAudioInputDevices: AudioInputDevices {
    var devices: [AudioInputDevice]
    var systemDefault: AudioInputDevice?
    private var onChange: (@MainActor () -> Void)?

    init(devices: [AudioInputDevice], systemDefault: AudioInputDevice?) {
        self.devices = devices
        self.systemDefault = systemDefault
    }

    func observe(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func changed() {
        onChange?()
    }
}

final class MemoryMicrophoneChoiceStore: MicrophoneChoiceStore, @unchecked Sendable {
    private(set) var chosen: ChosenMicrophone?

    func setChosen(_ chosen: ChosenMicrophone?) {
        self.chosen = chosen
    }
}

@MainActor
final class FakeLevelMeter: MicrophoneLevelMeter {
    private var onLevel: (@MainActor @Sendable (Double) -> Void)?
    private(set) var starts = 0
    var failure: Error?

    var isRunning: Bool {
        onLevel != nil
    }

    func start(onLevel: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        if let failure { throw failure }
        starts += 1
        self.onLevel = onLevel
    }

    func stop() {
        onLevel = nil
    }

    func hear(_ level: Double) {
        onLevel?(level)
    }
}
