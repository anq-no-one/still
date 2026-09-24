import AVFoundation
import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct AudioImportTests {
    private let folder = URL.temporaryDirectory.appending(path: "still-import-tests/\(UUID().uuidString)")

    private var audioRoot: URL {
        folder.appending(path: "Audio", directoryHint: .isDirectory)
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
        #expect(recording.transcript == "Ship the private beta on Friday")
        #expect(recording.segments.first?.start == 0)
        let note = try #require(recording.note)
        let sources = Set((note.summary + note.decisions + note.actions).flatMap(\.sourceSegmentIDs))
        #expect(!sources.isEmpty)
        #expect(sources.isSubset(of: recording.segments.map(\.id)))
        #expect(abs(recording.duration - 3) < 0.2)
        #expect(library.tracks(forRecording: recording.id) == [AudioImporter.track])
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

        #expect(importer.phase == .failed(AudioImportError.unsupported.localizedDescription))
        #expect(importer.failedFile == notes)
    }

    @Test
    func explainsADamagedAudioFile() async throws {
        let damaged = try file(named: "broken.wav")
        try Data(repeating: 7, count: 4_096).write(to: damaged)
        let library = try await makeLibrary()

        let importer = makeImporter(library: library, transcriber: StubOfflineTranscriber())
        await importer.start(damaged)?.value

        #expect(importer.phase == .failed(AudioImportError.damaged.localizedDescription))
        #expect(library.recordings.isEmpty)
        #expect(recordingAudio.isEmpty)
        #expect(stagedImports.isEmpty)
    }

    @Test
    func explainsAFileItCannotOpen() async throws {
        let missing = folder.appending(path: "moved away.m4a")

        let importer = makeImporter(library: try await makeLibrary(), transcriber: StubOfflineTranscriber())
        await importer.start(missing)?.value

        #expect(importer.phase == .failed(AudioImportError.inaccessible.localizedDescription))
        #expect(importer.failedFile == missing)
    }

    @Test
    func refusesAudioLongerThanTheLimit() async throws {
        let source = try AudioFileSource.inspect(try tone(named: "lecture.wav", seconds: 2))
        let writer = try AudioChunkWriter(
            directory: folder.appending(path: "staged", directoryHint: .isDirectory),
            cipher: LibraryCipher(key: .init(size: .bits256))
        )

        await #expect(throws: AudioImportError.tooLarge) {
            try await source.decode(into: writer, longest: 1)
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

    private var recordingAudio: [URL] {
        contents(of: audioRoot).filter { UUID(uuidString: $0.lastPathComponent) != nil }
    }

    private var stagedImports: [URL] {
        contents(of: audioRoot.appending(path: ".imports"))
    }

    private func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private func makeImporter(library: Library, transcriber: OfflineTranscriber) -> AudioImporter {
        AudioImporter(
            library: library,
            makeFinalTranscription: { FinalTranscription(transcriber: transcriber) }
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
                audioRoot: audioRoot,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { _ in MainActor.assumeIsolated { SpyAudioRecorder() } }
            )
        )
        await library.unlock()
        return library
    }

    private func file(named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name)
    }

    private func tone(named name: String, seconds: Double) throws -> URL {
        let url = try file(named: name)
        let sampleRate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings(for: url.pathExtension, sampleRate: sampleRate),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData?[channel][frame] = 0.3 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
        file.close()
        return url
    }

    private func settings(for fileExtension: String, sampleRate: Double) -> [String: Any] {
        guard fileExtension != "m4a" else {
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2]
        }

        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: fileExtension == "aiff",
        ]
    }
}

final class HookedTranscriber: OfflineTranscriber, @unchecked Sendable {
    var onTranscribe: @MainActor () -> Void = {}

    func segments(of pcm: Data, format: AudioFormat) async throws -> [TranscriptSegment] {
        await onTranscribe()
        return [TranscriptSegment(start: 0, end: 2, text: "Too late to keep", language: "en", confidence: 0.9)]
    }
}
