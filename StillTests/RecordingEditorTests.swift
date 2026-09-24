import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct RecordingEditorTests {
    @Test
    func aCorrectionKeepsWhatTheRecognizerHeard() async throws {
        let library = try await makeLibrary()
        let segments = words("Meeting with Ana .")
        let recording = Recording(title: "Call", transcript: segments.plainText, segments: segments, duration: 60)
        try library.add(recording)
        let editor = RecordingEditor(recording: recording, library: library)

        editor.correct(segments[2], to: "Anna")

        let corrected = try #require(editor.segment(withID: segments[2].id))
        #expect(corrected.text == "Ana")
        #expect(corrected.correction == "Anna")
        #expect(corrected.displayText == "Anna")
        #expect(corrected.isCorrected)
        #expect(editor.recording.transcript == "Meeting with Anna .")
    }

    @Test
    func applyingVocabularyToAnOldRecordingKeepsManualCorrectionsAndSources() async throws {
        let library = try await makeLibrary()
        let segments = [
            TranscriptSegment(start: 0, end: 2, text: "we deploy on cooper netties", language: "en", confidence: 0.9),
            TranscriptSegment(start: 2, end: 4, text: "cooper netties again", language: "en", confidence: 0.9, correction: "Kubernetes, said Dana"),
        ]
        let note = Note(template: .meeting, decisions: [NoteItem(text: "Deploy", sourceSegmentIDs: [segments[0].id])])
        let recording = Recording(title: "Ops", transcript: segments.plainText, segments: segments, note: note, duration: 60)
        try library.add(recording)
        var vocabulary = ProjectVocabulary(projectID: UUID())
        vocabulary.upsert(VocabularyTerm(term: "Kubernetes", variants: ["cooper netties"]))
        let editor = RecordingEditor(recording: recording, library: library)

        let changes = VocabularyCorrector.changes(vocabulary, for: recording.segments)
        #expect(changes.map(\.segmentID) == [segments[0].id])
        #expect(library.recordings.first?.segments[0].correction == nil)

        editor.apply(changes)
        editor.saveNow()

        let saved = try #require(library.recordings.first)
        #expect(saved.segments[0].displayText == "we deploy on Kubernetes")
        #expect(saved.segments[0].text == "we deploy on cooper netties")
        #expect(saved.segments[1].correction == "Kubernetes, said Dana")
        #expect(saved.note?.decisions.first?.sourceSegmentIDs == [segments[0].id])
    }

    @Test
    func revertingACorrectionDropsIt() async throws {
        let library = try await makeLibrary()
        let segments = words("Ana .")
        let recording = Recording(title: "Call", transcript: segments.plainText, segments: segments, duration: 60)
        try library.add(recording)
        let editor = RecordingEditor(recording: recording, library: library)

        editor.correct(segments[0], to: "Anna")
        editor.correct(segments[0], to: "Ana")

        #expect(editor.segment(withID: segments[0].id)?.isCorrected == false)
    }

    @Test
    func changingTheTemplateKeepsTheUsersOwnWords() async throws {
        let library = try await makeLibrary()
        let segments = words("We agreed to ship .")
        let recording = Recording(
            title: "Call",
            transcript: segments.plainText,
            segments: segments,
            note: Note(template: .meeting, summary: [NoteItem(text: "We agreed to ship .", sourceSegmentIDs: segments.map(\.id))]),
            duration: 60
        )
        try library.add(recording)
        let editor = RecordingEditor(recording: recording, library: library)

        editor.updateNoteText("Ask about the budget next time")
        editor.changeTemplate(to: .interview)

        #expect(editor.note.template == .interview)
        #expect(editor.note.isTemplateUserChosen)
        #expect(editor.note.userText == "Ask about the budget next time")
        #expect(editor.note.summary.count == 1)
    }

    @Test
    func userAddedItemsStayDistinguishable() async throws {
        let library = try await makeLibrary()
        let segments = words("We agreed to ship .")
        let recording = Recording(
            title: "Call",
            transcript: segments.plainText,
            segments: segments,
            note: Note(template: .meeting),
            duration: 60
        )
        try library.add(recording)
        let editor = RecordingEditor(recording: recording, library: library)

        editor.addAction("Email the summary", citing: segments[0])

        let action = try #require(editor.note.actions.first)
        #expect(action.isUserAuthored)
        #expect(action.sourceSegmentIDs == [segments[0].id])
    }

    @Test
    func editsReachTheLibraryOnSave() async throws {
        let library = try await makeLibrary()
        let segments = words("Draft .")
        let recording = Recording(title: "Draft", transcript: segments.plainText, segments: segments, duration: 60)
        try library.add(recording)
        let editor = RecordingEditor(recording: recording, library: library)

        editor.rename(to: "Weekly sync")
        editor.saveNow()

        #expect(library.recordings.map(\.title) == ["Weekly sync"])
        #expect(editor.saveFailure == nil)
    }

    private func makeLibrary() async throws -> Library {
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
                    MainActor.assumeIsolated {
                        EncryptedRecordingRepository(context: context, key: key)
                    }
                },
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } }
            )
        )
        await library.unlock()
        return library
    }
}

@MainActor
struct SpeakerRenameTests {
    @Test
    func renamingASpeakerLeavesTranscriptTextAlone() async throws {
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

        let speaker = Speaker.forTrack(.system)
        let segments = words("Hello everyone .").map { $0.attributed(to: speaker) }
        let recording = Recording(
            title: "Call",
            transcript: segments.plainText,
            segments: segments,
            speakers: [speaker],
            duration: 60
        )
        try library.add(recording)
        let editor = RecordingEditor(recording: recording, library: library)

        editor.renameSpeaker(speaker, to: "Anna")
        editor.saveNow()

        #expect(editor.recording.speakers.map(\.name) == ["Anna"])
        #expect(editor.recording.transcript == segments.plainText)
        #expect(editor.recording.segments.allSatisfy { $0.speakerID == speaker.id })
        #expect(editor.speaker(of: segments[0])?.name == "Anna")
    }
}
