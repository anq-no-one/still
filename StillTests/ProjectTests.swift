import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

struct ProjectSelectionTests {
    private let client = UUID()
    private let sideJob = UUID()

    @Test
    func allShowsEveryRecording() {
        let selection = ProjectSelection.all

        #expect(selection.isVisible(recording(in: client)))
        #expect(selection.isVisible(recording(in: nil)))
    }

    @Test
    func onlyShowsTheChosenProjects() {
        let selection = ProjectSelection(mode: .only, scopes: [.project(client)])

        #expect(selection.isVisible(recording(in: client)))
        #expect(!selection.isVisible(recording(in: sideJob)))
        #expect(!selection.isVisible(recording(in: nil)))
    }

    @Test
    func exceptHidesTheChosenProjects() {
        let selection = ProjectSelection(mode: .except, scopes: [.project(sideJob)])

        #expect(selection.isVisible(recording(in: client)))
        #expect(!selection.isVisible(recording(in: sideJob)))
        #expect(selection.isVisible(recording(in: nil)))
    }

    @Test
    func noProjectIsSelectableLikeAProject() {
        let only = ProjectSelection(mode: .only, scopes: [.noProject])
        let except = ProjectSelection(mode: .except, scopes: [.noProject])

        #expect(only.isVisible(recording(in: nil)))
        #expect(!only.isVisible(recording(in: client)))
        #expect(!except.isVisible(recording(in: nil)))
        #expect(except.isVisible(recording(in: client)))
    }

    @Test
    func onlyOneProjectNamesItAsTheDefault() {
        #expect(ProjectSelection(mode: .only, scopes: [.project(client)]).soleProjectID == client)
        #expect(ProjectSelection(mode: .only, scopes: [.project(client), .project(sideJob)]).soleProjectID == nil)
        #expect(ProjectSelection(mode: .only, scopes: [.noProject]).soleProjectID == nil)
        #expect(ProjectSelection(mode: .except, scopes: [.project(client)]).soleProjectID == nil)
    }

    @Test
    func theDeviceSelectionSurvivesARelaunch() throws {
        let suite = "still.projects.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = ProjectSelection(mode: .except, scopes: [.project(client), .noProject])

        #expect(UserDefaultsProjectSelectionStore(defaults: defaults).load() == .all)

        UserDefaultsProjectSelectionStore(defaults: defaults).save(selection)

        #expect(UserDefaultsProjectSelectionStore(defaults: defaults).load() == selection)
    }

    private func recording(in projectID: UUID?) -> Recording {
        Recording(title: "Standup", transcript: "text", duration: 60, projectID: projectID)
    }
}

struct ProjectMergeTests {
    @Test
    func keepsARenameAndARecolorFromTwoDevices() {
        let base = Project(name: "Acme", color: .blue, createdAt: Date(timeIntervalSince1970: 0))
        var renamed = base
        renamed.rename(to: "Acme Corp", at: Date(timeIntervalSince1970: 100))
        var recolored = base
        recolored.recolor(to: .orange, at: Date(timeIntervalSince1970: 200))

        let merged = Project.merge(renamed, recolored)

        #expect(merged.name == "Acme Corp")
        #expect(merged.color == .orange)
        #expect(merged == Project.merge(recolored, renamed))
    }

    @Test
    func theLaterEditOfOneFieldWins() {
        let base = Project(name: "Acme", color: .blue, createdAt: Date(timeIntervalSince1970: 0))
        var early = base
        early.setArchived(true, at: Date(timeIntervalSince1970: 100))
        var late = base
        late.setArchived(false, at: Date(timeIntervalSince1970: 200))

        #expect(!Project.merge(early, late).isArchived)
        #expect(!Project.merge(late, early).isArchived)
    }

    @Test
    func aRecordingFollowsTheLaterProjectMove() {
        let first = UUID()
        let second = UUID()
        var local = Recording(title: "Call", transcript: "text", duration: 60, updatedAt: Date(timeIntervalSince1970: 300))
        local.projectID = first
        local.projectAssignedAt = Date(timeIntervalSince1970: 100)
        var remote = local
        remote.projectID = second
        remote.projectAssignedAt = Date(timeIntervalSince1970: 200)
        remote.updatedAt = Date(timeIntervalSince1970: 200)

        #expect(RecordingMerge.merge(local, remote).projectID == second)
        #expect(RecordingMerge.merge(remote, local).projectID == second)
    }
}

@MainActor
struct LibraryProjectTests {
    @Test
    func projectsAreStoredSealed() async throws {
        let context = try makeContext()
        let library = try await makeUnlockedLibrary(context: context)

        try library.createProject(named: "Secret client", color: .red)

        let stored = try #require(try context.fetch(FetchDescriptor<EncryptedProject>()).first)
        #expect(!String(decoding: stored.sealedContent, as: UTF8.self).contains("Secret client"))

        let reopened = try await makeUnlockedLibrary(context: context)
        #expect(reopened.projects.map(\.name) == ["Secret client"])
        #expect(reopened.projects.first?.color == .red)
    }

    @Test
    func creatingWithoutAColorTakesTheFirstUnusedOne() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())

        let first = try library.createProject(named: "Acme")
        let second = try library.createProject(named: "Beta")

        #expect(first.color == .red)
        #expect(second.color == .orange)
        #expect(library.nextUnusedProjectColor == .yellow)
        #expect(library.projects.map(\.name) == ["Acme", "Beta"])
    }

    @Test
    func creatingPastEveryColorFallsBackToBlue() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())

        for color in ProjectColor.allCases {
            try library.createProject(named: color.rawValue, color: color)
        }

        #expect(library.nextUnusedProjectColor == .blue)
        #expect(try library.createProject(named: "Overflow").color == .blue)
    }

    @Test
    func assignsSeveralRecordingsAtOnceAndKeepsItAcrossRelaunch() async throws {
        let context = try makeContext()
        let library = try await makeUnlockedLibrary(context: context)
        let project = try library.createProject(named: "Acme", color: .blue)
        let first = Recording(title: "One", transcript: "a", duration: 5)
        let second = Recording(title: "Two", transcript: "b", duration: 5)
        try library.add(first)
        try library.add(second)

        try library.assign([first.id, second.id], toProject: project.id)

        #expect(library.recordings.allSatisfy { $0.projectID == project.id })

        let reopened = try await makeUnlockedLibrary(context: context)
        #expect(reopened.recordings.allSatisfy { $0.projectID == project.id })
    }

    @Test
    func aStaleEditorCopyCannotUndoAMove() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let project = try library.createProject(named: "Acme", color: .blue)
        let recording = Recording(title: "Call", transcript: "text", duration: 5)
        try library.add(recording)

        try library.assign([recording.id], toProject: project.id)
        var stale = recording
        stale.title = "Renamed while open"
        try library.save(stale)

        let saved = try #require(library.recordings.first)
        #expect(saved.title == "Renamed while open")
        #expect(saved.projectID == project.id)
    }

    @Test
    func hiddenProjectsLeaveEveryListAndSearch() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let work = try library.createProject(named: "Work", color: .blue)
        let other = try library.createProject(named: "Other job", color: .green)
        try library.add(Recording(title: "Work budget", transcript: "budget", duration: 5, projectID: work.id))
        try library.add(Recording(title: "Other budget", transcript: "budget", duration: 5, projectID: other.id))
        try library.add(Recording(title: "Loose budget", transcript: "budget", duration: 5))

        library.setProjectSelection(ProjectSelection(mode: .only, scopes: [.project(work.id)]))

        #expect(library.recordings.map(\.title) == ["Work budget"])
        #expect(library.recordingsInEveryProject.count == 3)
        let found = Set(LibrarySearch.results(for: "budget", in: library.recordings).map(\.recordingID))
        #expect(found == Set(library.recordings.map(\.id)))
        let filtered = LibrarySearch.results(
            for: "budget",
            in: library.recordingsInEveryProject,
            visibleTo: library.visibility
        )
        #expect(Set(filtered.map(\.recordingID)) == found)
    }

    @Test
    func aMacWithOneProjectFilesNewRecordingsThere() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let project = try library.createProject(named: "Acme", color: .blue)
        library.setProjectSelection(ProjectSelection(mode: .only, scopes: [.project(project.id)]))
        let coordinator = RecordingCoordinator(
            library: library,
            entitlements: Entitlements(source: FakeEntitlementSource(), cache: MemoryEntitlementCache()),
            makeSession: { FakeTranscriptionSession() },
            makeFinalTranscription: { FinalTranscription(transcriber: StubOfflineTranscriber(), windowSeconds: 3_600) }
        )

        await coordinator.toggle()
        await coordinator.toggle()

        #expect(library.recordings.map(\.projectID) == [project.id])
    }

    @Test
    func noDefaultProjectWithoutASingleActiveChoice() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        var project = try library.createProject(named: "Acme", color: .blue)
        let other = try library.createProject(named: "Beta", color: .red)

        #expect(library.defaultProjectID == nil)

        library.setProjectSelection(ProjectSelection(mode: .only, scopes: [.project(project.id), .project(other.id)]))
        #expect(library.defaultProjectID == nil)

        library.setProjectSelection(ProjectSelection(mode: .only, scopes: [.project(project.id)]))
        #expect(library.defaultProjectID == project.id)

        project.setArchived(true)
        try library.saveProject(project)
        #expect(library.defaultProjectID == nil)
    }

    @Test
    func projectsTravelThroughSyncAndMerge() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let project = try library.createProject(named: "Acme", color: .blue, at: Date(timeIntervalSince1970: 0))
        var renamed = project
        renamed.rename(to: "Acme Corp", at: Date(timeIntervalSince1970: 50))
        try library.saveProject(renamed)
        let transport = SpySyncTransport()
        let engine = SyncEngine(library: library, transport: transport, settings: MemorySyncSettings())
        var remote = project
        remote.recolor(to: .pink, at: Date(timeIntervalSince1970: 100))
        let newcomer = Project(name: "Beta", color: .mint)
        transport.incoming = try [remote, newcomer].map { project in
            SyncChange(
                id: project.id,
                kind: .project,
                updatedAt: project.updatedAt,
                deviceID: UUID(),
                payload: try library.sealForSync(project)
            )
        }

        engine.enable()
        await engine.sync()

        #expect(library.projects.map(\.name) == ["Acme Corp", "Beta"])
        #expect(library.project(withID: project.id)?.color == .pink)
        let pushed = try #require(transport.pushed.first)
        #expect(pushed.filter { $0.kind == .project }.map(\.id) == [project.id])
        #expect(pushed.allSatisfy { !String(decoding: $0.payload ?? Data(), as: UTF8.self).contains("Acme") })
    }

    @Test
    func aLeavingProjectKeepsSyncingUntilAnotherDeviceKeepsIt() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let hidden = try library.createProject(named: "Elsewhere", color: .red)
        try library.add(Recording(title: "Elsewhere", transcript: "text", duration: 5, projectID: hidden.id, projectAssignedAt: .now))
        library.setProjectSelection(ProjectSelection(mode: .except, scopes: [.project(hidden.id)]))
        let transport = SpySyncTransport()
        let engine = SyncEngine(library: library, transport: transport, settings: MemorySyncSettings())

        engine.enable()
        await engine.sync()

        #expect(library.recordings.isEmpty)
        #expect(library.storage(of: .project(hidden.id)) == .leaving)
        #expect(transport.pushed.first?.filter { $0.kind == .recording }.count == 1)
    }

    @Test
    func aRestrictedDeviceSkipsAudioOfHiddenRecordings() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let hidden = UUID()
        let visible = Recording(title: "Mine", transcript: "text", duration: 5)
        let elsewhere = Recording(title: "Theirs", transcript: "text", duration: 5, projectID: hidden)
        try library.add(visible)
        try library.add(elsewhere)
        library.setProjectSelection(ProjectSelection(mode: .except, scopes: [.project(hidden)]))

        let sender = try Scratch()
        let receiver = try Scratch()
        let transport = FakeChunkTransport()
        let senderCipher = LibraryCipher(key: SymmetricKey(data: Data(repeating: 7, count: 32)))
        let noProjectScope = try #require(library.scopeID(for: .noProject))
        let noProjectKey = try #require(library.scopeKey(for: noProjectScope))
        for (recording, scopeKey) in [(visible, noProjectKey), (elsewhere, SymmetricKey(size: .bits256))] {
            try writeAudio(forRecording: recording.id, in: sender.directory)
            await AudioChunkSync(
                audioRoot: sender.directory,
                transport: transport,
                freeBytes: { _ in 1 << 30 },
                sealing: { _ in ScopeChunkSealing(local: senderCipher, scopeKey: scopeKey) }
            )
            .sync(recordingID: recording.id)
        }

        let receiving = AudioChunkSync(
            audioRoot: receiver.directory,
            transport: transport,
            freeBytes: { _ in 1 << 30 },
            keepsAudio: library.keepsAudio(forRecording:),
            sealing: library.audioSealing(forRecording:)
        )
        await receiving.sync(recordingID: visible.id)
        await receiving.sync(recordingID: elsewhere.id)

        #expect(!AudioChunkStore.tracks(forRecording: visible.id, in: receiver.directory).isEmpty)
        #expect(AudioChunkStore.tracks(forRecording: elsewhere.id, in: receiver.directory).isEmpty)
    }

    private func writeAudio(forRecording id: UUID, in root: URL) throws {
        let format = AudioFormat(sampleRate: 1_000, channels: 1, bitsPerSample: 16)
        let writer = try AudioChunkWriter(
            directory: AudioChunkStore.trackDirectory(forRecording: id, track: .microphone, in: root),
            cipher: LibraryCipher(key: SymmetricKey(data: Data(repeating: 7, count: 32))),
            format: format,
            chunkSeconds: 5
        )
        try writer.append(Data(repeating: 3, count: 6 * format.bytesPerSecond))
        try writer.finish()
    }

    private let keySource = FakeDeviceKeySource()

    private func makeUnlockedLibrary(context: ModelContext) async throws -> Library {
        let audioRoot = try Scratch().directory
        let library = Library(
            keyRing: LibraryKeyRing(source: keySource),
            services: LibraryServices(
                audioRoot: audioRoot,
                makeRepository: { key in
                    MainActor.assumeIsolated { EncryptedRecordingRepository(context: context, key: key) }
                },
                makeRecorder: { key in
                    MainActor.assumeIsolated { WritingRecorder(root: audioRoot, cipher: LibraryCipher(key: key)) }
                },
                makeProjectRepository: { key in
                    MainActor.assumeIsolated { EncryptedProjectRepository(context: context, key: key) }
                }
            )
        )
        await library.unlock()
        return library
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: EncryptedRecording.self, EncryptedProject.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }
}
