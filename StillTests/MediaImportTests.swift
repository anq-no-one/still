import AVFoundation
import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct MediaImportTests {
    private let folder = URL.temporaryDirectory.appending(path: "still-import-tests/\(UUID().uuidString)")

    private var audioRoot: URL {
        folder.appending(path: "Audio", directoryHint: .isDirectory)
    }

    private var inbox: URL {
        folder.appending(path: "Inbox", directoryHint: .isDirectory)
    }

    @Test(arguments: ["m4a", "wav", "aiff", "caf"])
    func importsAnAudioFileAsOnePlayableSearchableRecording(_ fileExtension: String) async throws {
        let source = try tone(named: "Weekly sync.\(fileExtension)", seconds: 3)
        let original = try Data(contentsOf: source)
        let library = try await makeLibrary()
        let transcriber = StubOfflineTranscriber()
        transcriber.result = "Ship the private beta on Friday"
        let importer = makeImporter(library: library, transcriber: transcriber)

        await importer.start(source)?.value

        let recording = try #require(library.recordings.first)
        #expect(library.recordings.count == 1)
        #expect(importer.phase == .imported(recording.id))
        #expect(recording.title == "Weekly sync")
        #expect(recording.importedFrom == ImportedFile(name: "Weekly sync.\(fileExtension)", kind: .audio))
        #expect(recording.transcript == "Ship the private beta on Friday")
        #expect(recording.segments.first?.start == 0)
        let note = try #require(recording.note)
        let sources = Set((note.summary + note.decisions + note.actions).flatMap(\.sourceSegmentIDs))
        #expect(!sources.isEmpty)
        #expect(sources.isSubset(of: recording.segments.map(\.id)))
        #expect(abs(recording.duration - 3) < 0.2)
        #expect(library.tracks(forRecording: recording.id) == [MediaImporter.track])
        #expect(try library.audio(for: recording).count > 2 * AudioFormat.transcription.bytesPerSecond)
        #expect(!LibrarySearch.results(for: "private beta", in: library.recordings).isEmpty)
        #expect(try Data(contentsOf: source) == original)
        #expect(stagedImports.isEmpty)
    }

    @Test
    func importingTheSameAudioAgainOpensTheRecordingItAlreadyMade() async throws {
        let source = try tone(named: "standup.wav", seconds: 2)
        let copy = folder.appending(path: "standup copy.wav")
        try FileManager.default.copyItem(at: source, to: copy)
        let library = try await makeLibrary()
        let transcriber = StubOfflineTranscriber()
        let importer = makeImporter(library: library, transcriber: transcriber)

        await importer.start(source)?.value
        let first = try #require(library.recordings.first)
        let callsAfterFirstImport = transcriber.calls
        importer.dismiss()
        await importer.start(copy)?.value

        #expect(library.recordings.map(\.id) == [first.id])
        #expect(importer.phase == .imported(first.id))
        #expect(transcriber.calls == callsAfterFirstImport)
    }

    @Test
    func aRetryAfterAFailedImportAddsExactlyOneRecording() async throws {
        let source = try tone(named: "interview.caf", seconds: 2)
        let original = try Data(contentsOf: source)
        let library = try await makeLibrary()
        let transcriber = StubOfflineTranscriber()
        transcriber.error = WindowTranscriber.Interrupted()
        let importer = makeImporter(library: library, transcriber: transcriber)

        await importer.start(source)?.value

        #expect(importer.isFailed)
        #expect(importer.failedFile == source)
        #expect(library.recordings.isEmpty)
        #expect(recordingAudio.isEmpty)

        transcriber.error = nil
        await importer.retry()?.value

        #expect(library.recordings.count == 1)
        #expect(library.recordings.first.map { importer.phase == .imported($0.id) } == true)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test
    func cancellingWhileTranscribingLeavesNoRecordingAndNoAudio() async throws {
        let source = try tone(named: "all hands.m4a", seconds: 2)
        let library = try await makeLibrary()
        let transcriber = HookedTranscriber()
        let importer = makeImporter(library: library, transcriber: transcriber)
        transcriber.onTranscribe = { importer.cancel() }

        await importer.start(source)?.value

        #expect(importer.phase == .idle)
        #expect(library.recordings.isEmpty)
        #expect(recordingAudio.isEmpty)
        #expect(stagedImports.isEmpty)
    }

    @Test
    func cancellingBeforeTheFileIsReadLeavesNothingBehind() async throws {
        let source = try tone(named: "planning.wav", seconds: 1)
        let library = try await makeLibrary()
        let importer = makeImporter(library: library, transcriber: StubOfflineTranscriber())

        let task = importer.start(source)
        importer.cancel()
        await task?.value

        #expect(importer.phase == .idle)
        #expect(library.recordings.isEmpty)
        #expect(recordingAudio.isEmpty)
    }

    @Test
    func refusesAFileThatIsNotAudio() async throws {
        let notes = try file(named: "notes.txt")
        try Data("Agenda".utf8).write(to: notes)

        let importer = makeImporter(library: try await makeLibrary(), transcriber: StubOfflineTranscriber())
        await importer.start(notes)?.value

        #expect(importer.phase == .failed(MediaImportError.unsupported.localizedDescription))
        #expect(importer.failedFile == notes)
    }

    @Test
    func explainsADamagedAudioFile() async throws {
        let damaged = try file(named: "broken.wav")
        try Data(repeating: 7, count: 4_096).write(to: damaged)
        let library = try await makeLibrary()

        let importer = makeImporter(library: library, transcriber: StubOfflineTranscriber())
        await importer.start(damaged)?.value

        #expect(importer.phase == .failed(MediaImportError.damaged.localizedDescription))
        #expect(library.recordings.isEmpty)
        #expect(recordingAudio.isEmpty)
        #expect(stagedImports.isEmpty)
    }

    @Test
    func explainsAFileItCannotOpen() async throws {
        let missing = folder.appending(path: "moved away.m4a")

        let importer = makeImporter(library: try await makeLibrary(), transcriber: StubOfflineTranscriber())
        await importer.start(missing)?.value

        #expect(importer.phase == .failed(MediaImportError.inaccessible.localizedDescription))
        #expect(importer.failedFile == missing)
    }

    @Test
    func refusesAudioLongerThanTheLimit() async throws {
        let source = try MediaFile.inspect(try tone(named: "lecture.wav", seconds: 2))

        await #expect(throws: MediaImportError.tooLarge) {
            try await source.soundTrack(longest: 1)
        }
    }

    @Test
    func refusesSilenceWithoutKeepingItsAudio() async throws {
        let source = try tone(named: "muted.wav", seconds: 1)
        let library = try await makeLibrary()
        let transcriber = StubOfflineTranscriber()
        transcriber.result = ""

        let importer = makeImporter(library: library, transcriber: transcriber)
        await importer.start(source)?.value

        #expect(importer.phase == .failed(RecordingWorkflowError.emptyTranscript.localizedDescription))
        #expect(library.recordings.isEmpty)
        #expect(recordingAudio.isEmpty)
    }

    @Test
    func unlockingClearsAnImportThatWasInterrupted() async throws {
        let leftover = audioRoot.appending(path: ".imports/\(UUID().uuidString)/system", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)

        _ = try await makeLibrary()

        #expect(!FileManager.default.fileExists(atPath: audioRoot.appending(path: ".imports").path))
    }

    @Test
    func theImportIdentityIsKeyedToTheLibrary() {
        let digest = Data(repeating: 1, count: 32)
        let key = SymmetricKey(size: .bits256)

        #expect(ImportIdentity.recordingID(forContentDigest: digest, key: key)
            == ImportIdentity.recordingID(forContentDigest: digest, key: key))
        #expect(ImportIdentity.recordingID(forContentDigest: digest, key: key)
            != ImportIdentity.recordingID(forContentDigest: digest, key: SymmetricKey(size: .bits256)))
    }

    @Test(arguments: ["mov", "mp4", "m4v"])
    func importsTheSoundOfAVideoAsOneSearchableRecording(_ fileExtension: String) async throws {
        let source = try await movie(named: "Design review.\(fileExtension)", seconds: 3)
        let original = try Data(contentsOf: source)
        let library = try await makeLibrary()
        let transcriber = StubOfflineTranscriber()
        transcriber.result = "Ship the private beta on Friday"
        let importer = makeImporter(library: library, transcriber: transcriber)

        await importer.start(source)?.value

        let recording = try #require(library.recordings.first)
        #expect(library.recordings.count == 1)
        #expect(importer.phase == .imported(recording.id))
        #expect(recording.title == "Design review")
        #expect(recording.importedFrom == ImportedFile(name: "Design review.\(fileExtension)", kind: .video))
        #expect(!recording.isProjectConfirmed)
        #expect(recording.transcript == "Ship the private beta on Friday")
        let note = try #require(recording.note)
        let sources = Set((note.summary + note.decisions + note.actions).flatMap(\.sourceSegmentIDs))
        #expect(!sources.isEmpty)
        #expect(sources.isSubset(of: recording.segments.map(\.id)))
        #expect(abs(recording.duration - 3) < 0.3)
        #expect(try library.audio(for: recording).count > 2 * AudioFormat.transcription.bytesPerSecond)
        #expect(!LibrarySearch.results(for: "private beta", in: library.recordings).isEmpty)
        #expect(try Data(contentsOf: source) == original)
        #expect(stagedImports.isEmpty)
        #expect(try storedFiles().allSatisfy { try Data(contentsOf: $0).range(of: original.prefix(64)) == nil })
        #expect(try storedFiles().allSatisfy { !["mov", "mp4", "m4v"].contains($0.pathExtension) })
    }

    @Test
    func explainsThatAVideoWithoutSoundHasNothingToTranscribe() async throws {
        let source = try await movie(named: "screen capture.mov", seconds: 1, withSound: false)
        let library = try await makeLibrary()

        let importer = makeImporter(library: library, transcriber: StubOfflineTranscriber())
        await importer.start(source)?.value

        #expect(importer.phase == .failed(MediaImportError.silentVideo.localizedDescription))
        #expect(library.recordings.isEmpty)
        #expect(recordingAudio.isEmpty)
        #expect(stagedImports.isEmpty)
    }

    @Test
    func explainsAVideoCutShortWithoutKeepingAnything() async throws {
        let source = try await movie(named: "call.mov", seconds: 2)
        let whole = try Data(contentsOf: source)
        try whole.prefix(whole.count / 2).write(to: source)
        let library = try await makeLibrary()

        let importer = makeImporter(library: library, transcriber: StubOfflineTranscriber())
        await importer.start(source)?.value

        #expect(importer.phase == .failed(MediaImportError.damaged.localizedDescription))
        #expect(library.recordings.isEmpty)
        #expect(recordingAudio.isEmpty)
        #expect(stagedImports.isEmpty)
    }

    @Test
    func explainsAVideoThatIsNotAVideo() async throws {
        let source = try file(named: "garbled.mp4")
        try Data(repeating: 3, count: 8_192).write(to: source)

        let importer = makeImporter(library: try await makeLibrary(), transcriber: StubOfflineTranscriber())
        await importer.start(source)?.value

        #expect(importer.phase == .failed(MediaImportError.damaged.localizedDescription))
    }

    @Test
    func waitsForFreeSpaceAndThenImportsExactlyOnce() async throws {
        let source = try await movie(named: "retro.mov", seconds: 2)
        let capacity = Capacity(bytes: 1_000)
        let library = try await makeLibrary(capacity: capacity)
        let importer = makeImporter(library: library, transcriber: StubOfflineTranscriber())

        await importer.start(source)?.value

        #expect(importer.phase == .failed(MediaImportError.insufficientSpace.localizedDescription))
        #expect(library.recordings.isEmpty)
        #expect(recordingAudio.isEmpty)
        #expect(stagedImports.isEmpty)

        capacity.bytes = nil
        await importer.retry()?.value
        importer.dismiss()
        await importer.start(source)?.value

        #expect(library.recordings.count == 1)
        #expect(library.recordings.first.map { importer.phase == .imported($0.id) } == true)
    }

    @Test
    func cancellingAVideoImportLeavesNothingBehind() async throws {
        let source = try await movie(named: "kickoff.mp4", seconds: 2)
        let original = try Data(contentsOf: source)
        let library = try await makeLibrary()
        let transcriber = HookedTranscriber()
        let importer = makeImporter(library: library, transcriber: transcriber)
        transcriber.onTranscribe = { importer.cancel() }

        await importer.start(source)?.value

        #expect(importer.phase == .idle)
        #expect(library.recordings.isEmpty)
        #expect(recordingAudio.isEmpty)
        #expect(stagedImports.isEmpty)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test
    func aHandedOverCopyIsDeletedOnceItsSoundIsImported() async throws {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let copy = inbox.appending(path: "Shared call.mov")
        try await MediaFixtures.movie(at: copy, seconds: 1, withSound: true)
        let library = try await makeLibrary()

        await makeImporter(library: library, transcriber: StubOfflineTranscriber()).start(copy)?.value

        #expect(library.recordings.map(\.title) == ["Shared call"])
        #expect(!FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
    }

    @Test
    func aHandedOverCopyStaysForTryAgainUntilTheImportIsClosed() async throws {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let copy = inbox.appending(path: "Muted call.mov")
        try await MediaFixtures.movie(at: copy, seconds: 1, withSound: false)
        let importer = makeImporter(library: try await makeLibrary(), transcriber: StubOfflineTranscriber())

        await importer.start(copy)?.value
        #expect(importer.failedFile == copy)
        #expect(FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))

        importer.dismiss()
        #expect(!FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
    }

    private var recordingAudio: [URL] {
        contents(of: audioRoot).filter { UUID(uuidString: $0.lastPathComponent) != nil }
    }

    private var stagedImports: [URL] {
        contents(of: audioRoot.appending(path: ".imports"))
    }

    private func storedFiles() throws -> [URL] {
        let files = FileManager.default.enumerator(at: audioRoot, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL } ?? []
        return try files.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
    }

    private func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private func makeImporter(library: Library, transcriber: OfflineTranscriber) -> MediaImporter {
        MediaImporter(
            library: library,
            makeFinalTranscription: { FinalTranscription(transcriber: transcriber) },
            handOverFolders: [inbox]
        )
    }

    private func makeLibrary(capacity: Capacity = Capacity(bytes: nil)) async throws -> Library {
        let container = try ModelContainer(
            for: EncryptedRecording.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        let library = Library(
            keyRing: LibraryKeyRing(source: FakeDeviceKeySource()),
            services: LibraryServices(
                audioRoot: audioRoot,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } },
                availableCapacity: { url in capacity.bytes ?? StorageCapacity.available(at: url) }
            )
        )
        await library.unlock()
        return library
    }

    private func file(named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name)
    }

    private func movie(named name: String, seconds: Int, withSound: Bool = true) async throws -> URL {
        let url = try file(named: name)
        try await MediaFixtures.movie(at: url, seconds: seconds, withSound: withSound)
        return url
    }

    private func tone(named name: String, seconds: Double) throws -> URL {
        let url = try file(named: name)
        try MediaFixtures.tone(at: url, seconds: seconds)
        return url
    }
}

final class Capacity {
    var bytes: Int64?

    init(bytes: Int64?) {
        self.bytes = bytes
    }
}

final class HookedTranscriber: OfflineTranscriber, @unchecked Sendable {
    var onTranscribe: @MainActor () -> Void = {}

    func segments(of pcm: Data, format: AudioFormat) async throws -> [TranscriptSegment] {
        await onTranscribe()
        return [TranscriptSegment(start: 0, end: 2, text: "Too late to keep", language: "en", confidence: 0.9)]
    }
}
