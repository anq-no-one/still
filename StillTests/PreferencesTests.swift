import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Still

@MainActor
struct PreferencesTests {
    @Test
    func exportRoundTripsAllowedPreferencesToAnotherDevice() async throws {
        let acmeID = UUID()
        let sourceLibrary = try await makeUnlockedLibrary(context: try makeContext())
        try sourceLibrary.saveProject(Project(id: acmeID, name: "Acme", color: .blue))
        var vocabulary = ProjectVocabulary(projectID: acmeID)
        vocabulary.upsert(VocabularyTerm(term: "Kubernetes", variants: ["cooper netties"]))
        try sourceLibrary.saveVocabulary(vocabulary)
        sourceLibrary.retentionPolicy = .days30

        let sourceAllowList = MemoryAllowList(allowed: ["us.zoom.xos"])
        sourceAllowList.watches = true
        let sourceSiteList = MemorySiteAllowList(allowed: ["meet.google.com"])
        let sourceShortcut = MemoryShortcutStore()
        sourceShortcut.save(KeyCombo(keyCode: 15, modifiers: 2_304, key: "R"))
        let sourceMicrophone = MemoryMicrophoneChoiceStore()
        sourceMicrophone.setChosen(ChosenMicrophone(uid: "mic-1", name: "Mic One"))

        let exporter = PreferencesExporter(
            library: sourceLibrary,
            appLock: AppLock(settings: MemoryAppLockSettings(timeout: 900), authenticator: FakeOwnerAuthenticator()),
            automaticRecording: sourceAllowList,
            meetingSites: sourceSiteList,
            mediaHint: FakeMediaHintPreferencesStore(isOff: true),
            microphone: sourceMicrophone,
            shortcut: sourceShortcut
        )
        let data = try PreferencesCoder.encode(exporter.export())

        let targetLibrary = try await makeUnlockedLibrary(context: try makeContext())
        try targetLibrary.saveProject(Project(id: acmeID, name: "Acme", color: .green))
        let targetAllowList = MemoryAllowList(allowed: [])
        let targetSiteList = MemorySiteAllowList(allowed: [])
        let targetMediaHint = FakeMediaHintPreferencesStore(isOff: false)
        let targetMicrophone = MemoryMicrophoneChoiceStore()
        let targetShortcut = MemoryShortcutStore()
        let targetLock = AppLock(settings: MemoryAppLockSettings(), authenticator: FakeOwnerAuthenticator())

        let importer = PreferencesImporter(
            library: targetLibrary,
            appLock: targetLock,
            automaticRecording: targetAllowList,
            meetingSites: targetSiteList,
            mediaHint: targetMediaHint,
            microphone: targetMicrophone,
            shortcut: targetShortcut
        )
        let summary = try importer.apply(data)

        #expect(summary.vocabularyProjectCount == 1)
        #expect(summary.appliedRetentionPolicy)
        #expect(summary.appliedAppLockTimeout)
        #expect(summary.appliedAutomaticRecording)
        #expect(summary.appliedMeetingSites)
        #expect(summary.appliedMediaHint)
        #expect(summary.appliedMicrophone)
        #expect(summary.appliedShortcut)

        #expect(targetLibrary.retentionPolicy == .days30)
        #expect(targetLock.timeout == 900)
        #expect(targetAllowList.apps().first { $0.bundleID == "us.zoom.xos" }?.isAllowed == true)
        #expect(targetAllowList.watches)
        #expect(targetSiteList.sites().first { $0.host == "meet.google.com" }?.isAllowed == true)
        #expect(targetMediaHint.isOff)
        #expect(targetMicrophone.chosen == ChosenMicrophone(uid: "mic-1", name: "Mic One"))
        #expect(targetShortcut.load() == KeyCombo(keyCode: 15, modifiers: 2_304, key: "R"))
        #expect(targetLibrary.vocabulary(forProject: acmeID).activeTerms.map(\.term) == ["Kubernetes"])
    }

    @Test
    func vocabularyMatchesAHeldProjectByNameWhenIDsDiffer() async throws {
        let sourceLibrary = try await makeUnlockedLibrary(context: try makeContext())
        let sourceProject = try sourceLibrary.createProject(named: "Acme", color: .blue)
        var vocabulary = ProjectVocabulary(projectID: sourceProject.id)
        vocabulary.upsert(VocabularyTerm(term: "Kubernetes"))
        try sourceLibrary.saveVocabulary(vocabulary)

        let file = neutralExporter(library: sourceLibrary).export()

        let targetLibrary = try await makeUnlockedLibrary(context: try makeContext())
        let targetProject = try targetLibrary.createProject(named: "Acme", color: .red)
        #expect(targetProject.id != sourceProject.id)

        let summary = neutralImporter(library: targetLibrary).apply(file)

        #expect(summary.vocabularyProjectCount == 1)
        #expect(targetLibrary.vocabulary(forProject: targetProject.id).activeTerms.map(\.term) == ["Kubernetes"])
    }

    @Test
    func importSkipsAProjectThisDeviceDoesNotHoldRatherThanCreatingIt() async throws {
        let sourceLibrary = try await makeUnlockedLibrary(context: try makeContext())
        let ghost = try sourceLibrary.createProject(named: "Ghost Client", color: .purple)
        var vocabulary = ProjectVocabulary(projectID: ghost.id)
        vocabulary.upsert(VocabularyTerm(term: "Secret Codename"))
        try sourceLibrary.saveVocabulary(vocabulary)

        let file = neutralExporter(library: sourceLibrary).export()

        let targetLibrary = try await makeUnlockedLibrary(context: try makeContext())
        let summary = neutralImporter(library: targetLibrary).apply(file)

        #expect(summary.vocabularyProjectCount == 0)
        #expect(targetLibrary.projects.isEmpty)
    }

    @Test
    func importMergesIntoExistingVocabularyRatherThanReplacingIt() async throws {
        let sourceLibrary = try await makeUnlockedLibrary(context: try makeContext())
        let projectID = UUID()
        try sourceLibrary.saveProject(Project(id: projectID, name: "Acme", color: .blue))
        var incoming = ProjectVocabulary(projectID: projectID)
        incoming.upsert(VocabularyTerm(term: "Kubernetes", at: Date(timeIntervalSince1970: 100)))
        try sourceLibrary.saveVocabulary(incoming)
        let file = neutralExporter(library: sourceLibrary).export()

        let targetLibrary = try await makeUnlockedLibrary(context: try makeContext())
        try targetLibrary.saveProject(Project(id: projectID, name: "Acme", color: .blue))
        var existing = ProjectVocabulary(projectID: projectID)
        existing.upsert(VocabularyTerm(term: "Terraform", at: Date(timeIntervalSince1970: 50)))
        try targetLibrary.saveVocabulary(existing)

        neutralImporter(library: targetLibrary).apply(file)

        let merged = targetLibrary.vocabulary(forProject: projectID).activeTerms.map(\.term).sorted()
        #expect(merged == ["Kubernetes", "Terraform"])
    }

    @Test
    func importNeverChangesExcludedState() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        library.retentionPolicy = .forever

        let mcpSettings = FakeMCPAccessSettingsStore(enabled: true, approvedClients: ["trusted-tool"])
        let diagnosticsSettings = FakeDiagnosticsSettingsStore(enabled: true)
        let syncSettings = FakeSyncSettingsStore(enabled: false)
        let selectionStore = MemoryProjectSelectionStore(ProjectSelection(mode: .only, scopes: [.project(UUID())]))
        let selectionBefore = selectionStore.load()
        let lock = AppLock(settings: MemoryAppLockSettings(isEnabled: true, timeout: 60), authenticator: FakeOwnerAuthenticator())

        let file = PreferencesFile(retentionPolicy: .days90, appLockTimeout: 300)
        neutralImporter(library: library, appLock: lock).apply(file)

        #expect(mcpSettings.isEnabled())
        #expect(mcpSettings.approvedClients() == ["trusted-tool"])
        #expect(diagnosticsSettings.isEnabled())
        #expect(!syncSettings.isEnabled())
        #expect(selectionStore.load() == selectionBefore)
        #expect(lock.isEnabled)
        #expect(lock.timeout == 300)
    }

    @Test
    func malformedDataFailsClearlyAndLeavesSettingsIntact() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        library.retentionPolicy = .days90
        let lock = AppLock(settings: MemoryAppLockSettings(timeout: 120), authenticator: FakeOwnerAuthenticator())
        let importer = neutralImporter(library: library, appLock: lock)

        #expect(throws: PreferencesImportError.malformed) {
            try importer.apply(Data("not preferences json".utf8))
        }

        #expect(library.retentionPolicy == .days90)
        #expect(lock.timeout == 120)
    }

    @Test
    func newerVersionFailsClearlyAndLeavesSettingsIntact() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        library.retentionPolicy = .days90
        let lock = AppLock(settings: MemoryAppLockSettings(timeout: 120), authenticator: FakeOwnerAuthenticator())
        let importer = neutralImporter(library: library, appLock: lock)

        var future = PreferencesFile(retentionPolicy: .forever, appLockTimeout: 0)
        future.version = PreferencesFile.currentVersion + 1
        let data = try PreferencesCoder.encode(future)

        #expect(throws: PreferencesImportError.newerVersion(PreferencesFile.currentVersion + 1)) {
            try importer.apply(data)
        }

        #expect(library.retentionPolicy == .days90)
        #expect(lock.timeout == 120)
    }

    @Test
    func wrongKindFailsClearly() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let importer = neutralImporter(library: library)

        var wrongKind = PreferencesFile()
        wrongKind.kind = "something.else"
        let data = try PreferencesCoder.encode(wrongKind)

        #expect(throws: PreferencesImportError.unsupportedKind) {
            try importer.apply(data)
        }
    }

    @Test
    func exportedBytesContainNoSecretValuesEvenWhenSecretsExist() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        let project = try library.createProject(named: "Acme", color: .blue)
        var vocabulary = ProjectVocabulary(projectID: project.id)
        vocabulary.upsert(VocabularyTerm(term: "Kubernetes"))
        try library.saveVocabulary(vocabulary)

        let approvedClientMarker = "SECRET-MCP-CLIENT-4F2A91"
        _ = FakeMCPAccessSettingsStore(enabled: true, approvedClients: [approvedClientMarker])
        _ = FakeDiagnosticsSettingsStore(enabled: true)
        let recoveryMarker = "SECRET-RECOVERY-CODE-91XZ"
        _ = RecoveryCode(text: recoveryMarker)
        let deviceKeyMarker = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }

        let bytes = try PreferencesCoder.encode(neutralExporter(library: library).export())
        let text = String(decoding: bytes, as: UTF8.self)

        #expect(!text.contains(approvedClientMarker))
        #expect(!text.contains(recoveryMarker))
        #expect(!text.contains(deviceKeyMarker))
        #expect(!text.lowercased().contains("approved"))
        #expect(!text.lowercased().contains("recovery"))
        #expect(!text.lowercased().contains("diagnostic"))
        #expect(!text.lowercased().contains("selection"))
        #expect(text.contains("Kubernetes"))
    }

    private func neutralExporter(library: Library, appLock: AppLock? = nil) -> PreferencesExporter {
        PreferencesExporter(
            library: library,
            appLock: appLock ?? AppLock(settings: MemoryAppLockSettings(), authenticator: FakeOwnerAuthenticator()),
            automaticRecording: MemoryAllowList(allowed: []),
            meetingSites: MemorySiteAllowList(allowed: []),
            mediaHint: FakeMediaHintPreferencesStore(isOff: false),
            microphone: MemoryMicrophoneChoiceStore(),
            shortcut: MemoryShortcutStore()
        )
    }

    @Test
    func importingTellsTheLiveSettingsToReloadOnlyAfterSuccess() async throws {
        let library = try await makeUnlockedLibrary(context: try makeContext())
        var reloads = 0
        var importer = neutralImporter(library: library)
        importer.afterApply = { reloads += 1 }

        #expect(throws: (any Error).self) { try importer.apply(Data("not json".utf8)) }
        #expect(reloads == 0)

        try importer.apply(try PreferencesCoder.encode(PreferencesFile(retentionPolicy: .forever)))
        #expect(reloads == 1)
    }

    private func neutralImporter(library: Library, appLock: AppLock? = nil) -> PreferencesImporter {
        PreferencesImporter(
            library: library,
            appLock: appLock ?? AppLock(settings: MemoryAppLockSettings(), authenticator: FakeOwnerAuthenticator()),
            automaticRecording: MemoryAllowList(allowed: []),
            meetingSites: MemorySiteAllowList(allowed: []),
            mediaHint: FakeMediaHintPreferencesStore(isOff: false),
            microphone: MemoryMicrophoneChoiceStore(),
            shortcut: MemoryShortcutStore()
        )
    }

    private func makeUnlockedLibrary(context: ModelContext) async throws -> Library {
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
                makeProjectRepository: { key in
                    MainActor.assumeIsolated { EncryptedProjectRepository(context: context, key: key) }
                },
                makeVocabularyRepository: { key in
                    MainActor.assumeIsolated { EncryptedProjectVocabularyRepository(context: context, key: key) }
                }
            )
        )
        await library.unlock()
        return library
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: EncryptedRecording.self, EncryptedProject.self, EncryptedProjectVocabulary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        return ModelContext(container)
    }
}

final class FakeMediaHintPreferencesStore: MediaHintPreferencesStore, @unchecked Sendable {
    var isOff: Bool

    init(isOff: Bool) {
        self.isOff = isOff
    }
}

final class FakeMCPAccessSettingsStore: MCPAccessSettingsStore, @unchecked Sendable {
    private var enabled: Bool
    private var approved: [String]

    init(enabled: Bool, approvedClients: [String]) {
        self.enabled = enabled
        approved = approvedClients
    }

    func isEnabled() -> Bool { enabled }
    func setEnabled(_ enabled: Bool) { self.enabled = enabled }
    func approvedClients() -> [String] { approved }
    func setApprovedClients(_ names: [String]) { approved = names }
}

final class FakeDiagnosticsSettingsStore: DiagnosticsSettingsStore, @unchecked Sendable {
    private var enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func isEnabled() -> Bool { enabled }
    func setEnabled(_ enabled: Bool) { self.enabled = enabled }
}

final class FakeSyncSettingsStore: SyncSettingsStore, @unchecked Sendable {
    private var enabled: Bool
    private var syncedAt: Date?

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func isEnabled() -> Bool { enabled }
    func setEnabled(_ enabled: Bool) { self.enabled = enabled }
    func lastSyncedAt() -> Date? { syncedAt }
    func setLastSyncedAt(_ date: Date) { syncedAt = date }
}
