import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct SpeakerMergeTests {
    @Test
    func mergingMovesEveryLineToTheSurvivorAndDropsTheDuplicate() {
        let recording = mergedFixture()
        let duplicate = recording.speakers[1]
        let survivor = recording.speakers[2]

        let merged = recording.mergingSpeaker(duplicate, into: survivor)

        #expect(merged.speakers.map(\.id) == [recording.speakers[0].id, survivor.id])
        #expect(merged.speakers.map(\.name) == ["You", "Speaker 2"])
        #expect(merged.segments.map(\.speakerID) == [recording.speakers[0].id, survivor.id, survivor.id])
        #expect(merged.segments.map(\.id) == recording.segments.map(\.id))
    }

    @Test
    func mergingHandsAPendingSuggestionToASuggestionlessSurvivor() {
        var recording = mergedFixture()
        let duplicate = recording.speakers[1]
        let survivor = recording.speakers[2]
        recording.speakers[1] = duplicate.suggesting("Dana Kim")

        let merged = recording.mergingSpeaker(duplicate, into: survivor)

        #expect(merged.speakers.count == 2)
        #expect(merged.speakers[1].suggestedName == "Dana Kim")
        #expect(merged.speakers[1].name == "Speaker 2")
    }

    @Test
    func mergingAnUnknownOrIdenticalSpeakerChangesNothing() {
        let recording = mergedFixture()
        let stranger = Speaker(name: "Stranger", origin: .system, isYou: false)

        #expect(recording.mergingSpeaker(stranger, into: recording.speakers[0]) == recording)
        #expect(recording.mergingSpeaker(recording.speakers[0], into: stranger) == recording)
        #expect(recording.mergingSpeaker(recording.speakers[0], into: recording.speakers[0]) == recording)
    }

    @Test
    func theEditorMergesAndSaves() async throws {
        let library = try await makeLibrary()
        let recording = mergedFixture()
        try library.add(recording)
        let editor = RecordingEditor(recording: recording, library: library)

        editor.mergeSpeaker(recording.speakers[1], into: recording.speakers[2])
        editor.saveNow()

        #expect(editor.recording.speakers.map(\.name) == ["You", "Speaker 2"])
        #expect(editor.recording.segments.allSatisfy { $0.speakerID != recording.speakers[1].id })
        #expect(library.recordings.first?.speakers.map(\.name) == ["You", "Speaker 2"])
    }

    private func mergedFixture() -> Recording {
        let you = Speaker.forTrack(.microphone)
        let first = Speaker(name: "Speaker 1", origin: .system, isYou: false, nameSource: .diarization)
        let second = Speaker(name: "Speaker 2", origin: .system, isYou: false, nameSource: .diarization)
        let segments = [
            TranscriptSegment(start: 0, end: 2, text: "Hello", language: "en", confidence: 0.9).attributed(to: you),
            TranscriptSegment(start: 2, end: 4, text: "Hi", language: "en", confidence: 0.9).attributed(to: first),
            TranscriptSegment(start: 4, end: 6, text: "Hey", language: "en", confidence: 0.9).attributed(to: second),
        ]
        return Recording(
            title: "Call",
            transcript: segments.plainText,
            segments: segments,
            speakers: [you, first, second],
            duration: 6
        )
    }

    private func makeLibrary() async throws -> Library {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let library = Library(
            keyRing: LibraryKeyRing(source: FakeDeviceKeySource()),
            services: LibraryServices(
                audioRoot: try Scratch().directory,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } }
            )
        )
        await library.unlock()
        return library
    }
}
