import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct BrowserMeetingBridgeTests {
    private let meet = "meet.google.com"
    private let chrome = "com.google.Chrome"

    @Test
    func recordsOnlyForAnApprovedSite() async throws {
        let (bridge, coordinator) = try await make(allowed: [meet])

        await bridge.handle(BrowserMeetingEvent(host: "example.com", meetingID: "a", phase: .started))

        #expect(!coordinator.isRecording)

        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .started))

        #expect(coordinator.isRecording)
    }

    @Test
    func oneMeetingMakesOneRecording() async throws {
        let (bridge, coordinator) = try await make(allowed: [meet])
        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .started))
        let first = coordinator.workflow

        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .started))

        #expect(coordinator.workflow === first)

        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .ended))

        #expect(!coordinator.isRecording)
        #expect(bridge.activeMeetingID == nil)
    }

    @Test
    func anotherMeetingEndingDoesNotStopThisOne() async throws {
        let (bridge, coordinator) = try await make(allowed: [meet])
        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .started))

        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "b", phase: .ended))

        #expect(coordinator.isRecording)
    }

    @Test
    func turningOffASiteStopsFutureStarts() async throws {
        let (bridge, coordinator) = try await make(allowed: [meet])
        let site = try #require(bridge.sites.first { $0.host == meet })

        bridge.setAllowed(false, for: site)
        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .started))

        #expect(!coordinator.isRecording)
    }

    @Test
    func withoutTheExtensionManualRecordingStillWorks() async throws {
        let (_, coordinator) = try await make(allowed: [])

        await coordinator.start()

        #expect(coordinator.isRecording)
        #expect(coordinator.audioTarget.scope == .callApps)
    }

    @Test
    func aBrowserMeetingCapturesOnlyTheBrowserThatHostsIt() async throws {
        let (bridge, coordinator) = try await make(allowed: [meet])

        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .started, browserBundleID: chrome))

        #expect(coordinator.audioTarget.scope == .apps([chrome]))
    }

    @Test
    func aMeetingFromAnUnnamedBrowserCapturesBrowsersOnly() async throws {
        let (bridge, coordinator) = try await make(allowed: [meet])

        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .started))

        #expect(coordinator.audioTarget.scope == .browser(nil))
    }

    @Test
    func aZoomMeetingOnACompanySubdomainCounts() async throws {
        let (bridge, coordinator) = try await make(allowed: ["zoom.us"])

        await bridge.handle(BrowserMeetingEvent(host: "us02web.zoom.us", meetingID: "z", phase: .started))

        #expect(coordinator.isRecording)
    }

    @Test
    func aLookalikeHostDoesNotCount() async throws {
        let (bridge, coordinator) = try await make(allowed: ["zoom.us"])

        await bridge.handle(BrowserMeetingEvent(host: "notzoom.us", meetingID: "z", phase: .started))

        #expect(!coordinator.isRecording)
    }

    @Test
    func quittingTheHostBrowserEndsTheMeeting() async throws {
        let (bridge, coordinator) = try await make(allowed: [meet])
        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .started, browserBundleID: chrome))

        await bridge.browserQuit("com.apple.Safari")
        #expect(coordinator.isRecording)

        await bridge.browserQuit(chrome)
        #expect(!coordinator.isRecording)
        #expect(bridge.activeMeetingID == nil)
    }

    @Test
    func whoIsSpeakingNeverStartsARecording() async throws {
        let (bridge, coordinator) = try await make(allowed: [meet])

        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .speakerStarted, speaker: "Dana Kim"))

        #expect(!coordinator.isRecording)
        #expect(bridge.activeMeetingID == nil)
    }

    @Test
    func whoIsSpeakingKeepsTheMeetingGoing() async throws {
        let (bridge, coordinator) = try await make(allowed: [meet])
        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .started))

        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .speakerStarted, speaker: "Dana Kim"))
        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .speakerEnded, speaker: "Dana Kim"))

        #expect(coordinator.isRecording)
        #expect(bridge.activeMeetingID == "a")
    }

    @Test
    func speakerNamesAreIgnoredUntilTheUserTurnsThemOn() async throws {
        let (bridge, coordinator) = try await make(allowed: [meet])
        bridge.suggestsSpeakerNames = false
        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .started))

        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .speakerStarted, speaker: "Dana Kim"))
        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .speakerEnded, speaker: "Dana Kim"))
        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .ended))

        let recording = try #require(coordinator.library.recordings.first)
        #expect(recording.speakers.allSatisfy { $0.suggestedName == nil })
    }

    @Test
    func soundFromAnotherTabIsMarkedOnTheSavedRecording() async throws {
        let (bridge, coordinator) = try await make(allowed: [meet])
        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .started))

        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .mediaStarted))
        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .mediaEnded))
        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .ended))

        let recording = try #require(coordinator.library.recordings.first)
        #expect(recording.mixedMediaSpans?.count == 1)
    }

    @Test
    func soundFromAnotherTabOutsideTheMeetingIsIgnored() async throws {
        let (bridge, coordinator) = try await make(allowed: [meet])
        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .started))

        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "b", phase: .mediaStarted))
        await bridge.handle(BrowserMeetingEvent(host: meet, meetingID: "a", phase: .ended))

        #expect(coordinator.library.recordings.first?.mixedMediaSpans == nil)
    }

    private func make(allowed: [String]) async throws -> (BrowserMeetingBridge, RecordingCoordinator) {
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
                }
            )
        )
        await library.unlock()

        let coordinator = RecordingCoordinator(
            library: library,
            entitlements: Entitlements(source: FakeEntitlementSource(), cache: MemoryEntitlementCache()),
            makeSession: { FakeTranscriptionSession() },
            makeFinalTranscription: { FinalTranscription(transcriber: StubOfflineTranscriber(), windowSeconds: 3_600) }
        )
        let bridge = BrowserMeetingBridge(
            coordinator: coordinator,
            allowList: MemorySiteAllowList(allowed: Set(allowed))
        )
        return (bridge, coordinator)
    }
}

final class MemorySiteAllowList: MeetingSiteAllowList, @unchecked Sendable {
    private var allowed: Set<String>
    var suggestsSpeakerNames = true

    init(allowed: Set<String>) {
        self.allowed = allowed
    }

    func sites() -> [MeetingSite] {
        MeetingSite.supported.map {
            MeetingSite(host: $0.host, name: $0.name, isAllowed: allowed.contains($0.host))
        }
    }

    func setAllowed(_ isAllowed: Bool, forHost host: String) {
        if isAllowed {
            allowed.insert(host)
        } else {
            allowed.remove(host)
        }
    }
}
