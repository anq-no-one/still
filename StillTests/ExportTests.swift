import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

struct RecordingDocumentTests {
    @Test
    func markdownKeepsNoteStructureAndTimestamps() {
        let recording = sampleRecording()

        let markdown = RecordingDocument.markdown(for: recording)

        #expect(markdown.contains("# Budget review"))
        #expect(markdown.contains("## Meeting notes"))
        #expect(markdown.contains("### Decisions"))
        #expect(markdown.contains("### Action items"))
        #expect(markdown.contains("## Transcript"))
        #expect(markdown.contains("`0:00`"))
        #expect(markdown.contains("Ask about the budget"))
    }

    @Test
    func plainTextDropsMarkdownMarkers() {
        let text = RecordingDocument.plainText(for: sampleRecording())

        #expect(!text.contains("##"))
        #expect(text.contains("Budget review"))
        #expect(text.contains("Transcript"))
    }

    @Test
    func pdfProducesAReadablePDFDocument() {
        let pdf = PDFDocumentBuilder.pdf(from: RecordingDocument.plainText(for: sampleRecording()))

        #expect(pdf.prefix(4) == Data("%PDF".utf8))
        #expect(pdf.count > 500)
    }

    private func sampleRecording() -> Recording {
        let segments = words("We decided to delay the launch . Anna will send the timeline .")
        return Recording(
            title: "Budget review",
            transcript: segments.plainText,
            segments: segments,
            note: Note(
                template: .meeting,
                decisions: [NoteItem(text: "We decided to delay the launch .", sourceSegmentIDs: [segments[0].id])],
                actions: [NoteItem(text: "Anna will send the timeline .", sourceSegmentIDs: [segments[6].id])],
                userText: "Ask about the budget"
            ),
            duration: 300
        )
    }
}

@MainActor
struct StillArchiveTests {
    @Test
    func anArchiveRoundTripsThroughTheLibrary() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let library = try await makeLibrary(source: source, audioRoot: scratch.directory)
        let key = try await LibraryKeyRing(source: source).unlock(reason: "seed")
        let segments = words("Recorded words .")
        let recording = Recording(title: "Archived", transcript: segments.plainText, segments: segments, duration: 12)
        let format = AudioFormat.transcription
        let writer = try AudioChunkWriter(
            directory: AudioChunkStore.trackDirectory(forRecording: recording.id, track: .microphone, in: scratch.directory),
            cipher: LibraryCipher(key: key),
            format: format
        )
        try writer.append(Data(repeating: 6, count: format.bytesPerSecond))
        try writer.finish()
        try library.add(recording)

        let archive = try library.archive(recording, tracks: [.microphone])
        try library.delete(recording)

        #expect(library.recordings.isEmpty)

        let restored = try library.importArchive(archive)

        #expect(restored.id == recording.id)
        #expect(restored.transcript == recording.transcript)
        #expect(try library.capturedAudio(forRecording: recording.id).pcm.count == format.bytesPerSecond)
    }

    @Test
    func aTamperedArchiveDoesNotImport() async throws {
        let scratch = try Scratch()
        let source = FakeDeviceKeySource()
        let library = try await makeLibrary(source: source, audioRoot: scratch.directory)
        let recording = Recording(title: "Archived", transcript: "text", duration: 12)
        try library.add(recording)
        var archive = try library.archive(recording, tracks: [])
        archive[archive.count - 1] ^= 0xFF

        #expect(throws: StillArchiveError.unreadable) {
            try library.importArchive(archive)
        }
    }

    @Test
    func anotherKeyCannotOpenTheArchive() throws {
        let archive = StillArchive(
            version: StillArchive.currentVersion,
            recording: Recording(title: "Private", transcript: "secret", duration: 1),
            tracks: []
        )
        let sealed = try StillArchiveCoder.seal(archive, with: SymmetricKey(size: .bits256))

        #expect(throws: StillArchiveError.unreadable) {
            try StillArchiveCoder.open(sealed, with: SymmetricKey(size: .bits256))
        }
    }

    private func makeLibrary(source: FakeDeviceKeySource, audioRoot: URL) async throws -> Library {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let library = Library(
            keyRing: LibraryKeyRing(source: source),
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
