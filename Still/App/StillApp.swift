import CryptoKit
import SwiftData
import SwiftUI

@main
struct StillApp: App {
    private let library: Library
    private let models: ModelInstallers
    private let entitlements: Entitlements
    private let coordinator: RecordingCoordinator
    private let importer: MediaImporter
    private let setup: SetupFlow
    private let lock: AppLock
    private let sync: SyncEngine
    private let diagnostics: Diagnostics
    private let extraction: MemoryExtraction
    private let preferencesExporter: PreferencesExporter
    private let preferencesImporter: PreferencesImporter
    #if os(macOS)
    private let automatic: AutomaticRecording
    private let browser: BrowserMeetingBridge
    private let aiTools: MCPAccess
    private let chromium: ChromiumConnections
    private let microphones: MicrophoneChoice
    #endif

    private let navigation: LibraryNavigation
    private let preferences: SettingsPreferences
    #if os(macOS)
    private let shortcut: RecordingShortcut
    private let login: LaunchAtLogin
    private let mediaHint: MediaPlaybackHint
    @NSApplicationDelegateAdaptor private var presence: BackgroundPresence
    #endif

    static let libraryWindowID = "library"

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let launch = Perf.begin("launch.init")
        #if DEBUG
        UITestLaunch.resetIfRequested(keychainService: KeychainDeviceKeySource.defaultService)
        #endif

        // SwiftData turns on CloudKit mirroring by itself when the app carries
        // an iCloud entitlement. Still syncs through its own encrypted
        // transport, so that mirroring is refused: it would need optional
        // attributes and no unique id, and it would put the store in iCloud
        // outside Still's encryption.
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: EncryptedRecording.self, EncryptedProject.self, EncryptedProjectVocabulary.self,
                configurations: ModelConfiguration(cloudKitDatabase: .none)
            )
        } catch {
            fatalError("Unable to open the local Library store.")
        }

        let context = ModelContext(container)
        let audioRoot = URL.applicationSupportDirectory
            .appending(path: "Still/Audio", directoryHint: .isDirectory)

        let proEntitlements = MainActor.assumeIsolated { Entitlements(source: StoreKitEntitlementSource()) }
        entitlements = proEntitlements

        #if DEBUG
        let audioFixture = UITestLaunch.audioFixture
        #else
        let audioFixture: URL? = nil
        #endif
        let microphone = MainActor.assumeIsolated { MicrophoneInput(fixture: audioFixture) }
        let systemAudio = SystemAudioInput()
        #if os(macOS)
        let tileVoiceActivity = SystemVoiceActivity()
        try? systemAudio.attach { _ in { buffer in tileVoiceActivity.ingest(buffer) } }
        #endif
        let audioTarget = MainActor.assumeIsolated { SystemAudioTarget() }

        let supportRoot = URL.applicationSupportDirectory.appending(path: "Still", directoryHint: .isDirectory)

        #if DEBUG
        let modelRoot = UITestLaunch.modelRoot ?? supportRoot.appending(path: "Models", directoryHint: .isDirectory)
        #else
        let modelRoot = supportRoot.appending(path: "Models", directoryHint: .isDirectory)
        #endif
        let installers = MainActor.assumeIsolated {
            ModelInstallers(
                transcription: ModelPackInstaller(
                    pack: ModelCatalog.parakeetV3,
                    root: modelRoot,
                    downloader: URLSessionModelFileDownloader(),
                    approval: UserDefaultsModelApprovalStore()
                ),
                speakers: ModelPackInstaller(
                    pack: ModelCatalog.speakerSeparation,
                    root: modelRoot,
                    downloader: URLSessionModelFileDownloader(),
                    approval: UserDefaultsModelApprovalStore()
                ),
                meetingMemory: ModelPackInstaller(
                    pack: ModelCatalog.meetingMemory(forMemory: Int(ProcessInfo.processInfo.physicalMemory)),
                    root: modelRoot,
                    downloader: URLSessionModelFileDownloader(),
                    approval: UserDefaultsModelApprovalStore()
                )
            )
        }
        models = installers
        let speech = ParakeetEngine(pack: ModelCatalog.parakeetV3, root: modelRoot)
        let installer = installers.transcription

        let journal = MainActor.assumeIsolated {
            let journal = DiagnosticJournal(
                fileURL: supportRoot.appending(path: "Diagnostics/journal.jsonl"),
                key: (try? KeychainDeviceKeySource().journalKey()) ?? SymmetricKey(size: .bits256)
            )
            journal.note(.appLaunched)
            try? journal.removeExpired()
            return journal
        }

        let developer = MainActor.assumeIsolated {
            DeveloperDiagnostics(
                directory: supportRoot.appending(path: "Diagnostics/Developer", directoryHint: .isDirectory),
                key: (try? KeychainDeviceKeySource().journalKey()) ?? SymmetricKey(size: .bits256)
            )
        }

        let recordingLibrary = MainActor.assumeIsolated {
            Library(
                keyRing: LibraryKeyRing(source: KeychainDeviceKeySource()),
                services: LibraryServices(
                    audioRoot: audioRoot,
                    settingsFile: supportRoot.appending(path: "Library.settings"),
                    keysFile: supportRoot.appending(path: "Library.keys"),
                    makeRepository: { key in
                        MainActor.assumeIsolated {
                            EncryptedRecordingRepository(context: context, key: key)
                        }
                    },
                    makeRecorder: { key in
                        MainActor.assumeIsolated {
                            #if os(macOS)
                            MacAudioRecorder(
                                root: audioRoot,
                                cipher: LibraryCipher(key: key),
                                microphoneInput: microphone,
                                systemAudioInput: systemAudio,
                                capturesSystemAudio: { proEntitlements.allows(.macSystemAudio) },
                                scope: { audioTarget.scope },
                                tiles: MeetingTileSource(
                                    settings: UserDefaultsMeetingTileSettings(),
                                    isVoiceActive: { tileVoiceActivity.isActive() }
                                )
                            )
                            #else
                            MicrophoneRecorder(root: audioRoot, cipher: LibraryCipher(key: key), input: microphone)
                            #endif
                        }
                    },
                    makeEmbeddingEngine: {
                        guard proEntitlements.allows(.semanticSearch) else { return nil }
                        return await AppleSemanticEmbedding.makeEngine(allowDownload: installer.state == .installed)
                    },
                    makeProjectRepository: { key in
                        MainActor.assumeIsolated {
                            EncryptedProjectRepository(context: context, key: key)
                        }
                    },
                    makeVocabularyRepository: { key in
                        MainActor.assumeIsolated {
                            EncryptedProjectVocabularyRepository(context: context, key: key)
                        }
                    }
                ),
                selectionStore: UserDefaultsProjectSelectionStore(),
                journal: journal
            )
        }
        let setupFlow = MainActor.assumeIsolated {
            SetupFlow(
                store: UserDefaultsSetupProgressStore(),
                permissions: SystemSetupPermissions(),
                includesSystemAudio: SetupFlow.recordsSystemAudio,
                isTranscriptionReady: { installer.state == .installed }
            )
        }
        setup = setupFlow
        preferences = MainActor.assumeIsolated { SettingsPreferences() }
        lock = MainActor.assumeIsolated {
            AppLock(settings: UserDefaultsAppLockSettings(), authenticator: SystemOwnerAuthenticator())
        }
        library = recordingLibrary
        diagnostics = MainActor.assumeIsolated {
            Diagnostics(
                settings: UserDefaultsDiagnosticsSettings(),
                sink: NoDiagnosticsSink(),
                journal: journal,
                developer: developer,
                bundleContext: {
                    [
                        "transcriptionPack": "\(installers.transcription.pack.id)@\(installers.transcription.pack.version) \(installers.transcription.state)",
                        "speakerPack": "\(installers.speakers.pack.id)@\(installers.speakers.pack.version) \(installers.speakers.state)",
                        "meetingMemoryPack": "\(installers.meetingMemory.pack.id)@\(installers.meetingMemory.pack.version) \(installers.meetingMemory.state)",
                        "localModelCanRun": String(LocalModelExtractor.canRun),
                        "appleFoundationModel": String(FoundationModelTitle.isAvailable),
                        "semanticSearch": String(proEntitlements.allows(.semanticSearch)),
                    ]
                }
            )
        }

        let syncEngine = MainActor.assumeIsolated {
            SyncEngine(
                library: recordingLibrary,
                transport: CloudKitSyncTransport(),
                settings: UserDefaultsSyncSettings(),
                identity: DeviceIdentity(
                    agreementKey: (try? KeychainDeviceKeySource().agreementKey()) ?? .init(),
                    kind: .current
                )
            )
        }
        sync = syncEngine
        let makeFinalTranscription = { FinalTranscription(transcriber: ParakeetOfflineTranscriber(engine: speech)) }
        let makeSpeakerSeparation = {
            SpeakerSeparation(
                diarizer: FluidSpeakerDiarizer(pack: ModelCatalog.speakerSeparation, root: modelRoot),
                voiceprints: FluidVoiceprintExtractor(pack: ModelCatalog.speakerSeparation, root: modelRoot)
            )
        }
        let memoryInstaller = installers.meetingMemory
        let memoryExtractor = LocalModelExtractor(pack: memoryInstaller.pack, root: modelRoot)
        let detailsModel = LocalLanguageModel(directory: memoryInstaller.pack.installedDirectory(in: modelRoot))
        let makePreferredNoteBuilder: @MainActor @Sendable () -> GroundedNoteBuilder = {
            guard LocalModelExtractor.canRun, memoryInstaller.state == .installed else { return GroundedNoteBuilder() }
            return GroundedNoteBuilder(preferred: LocalModelNoteGenerator(model: detailsModel))
        }
        let makeDetailsTitle: @MainActor @Sendable (TitleRequest) async -> String? = { request in
            await TitleChain.first(of: [
                { await FoundationModelTitle().title(for: $0) },
                { request in
                    guard LocalModelExtractor.canRun, memoryInstaller.state == .installed else { return nil }
                    return await LocalModelTitle(model: detailsModel).title(for: request)
                },
            ], for: request)
        }
        let recordingCoordinator = MainActor.assumeIsolated {
            RecordingCoordinator(
                library: recordingLibrary,
                entitlements: proEntitlements,
                makeSession: { LiveTranscriber(input: microphone, systemAudio: systemAudio, engine: speech) },
                makeFinalTranscription: makeFinalTranscription,
                makeSpeakerSeparation: makeSpeakerSeparation,
                makeNoteBuilder: makePreferredNoteBuilder,
                makeTitle: makeDetailsTitle,
                meetingContext: { date in
                    await CalendarContext(source: EventKitCalendarSource()).suggestion(at: date)
                },
                isReady: { setupFlow.isComplete && recordingLibrary.state == .unlocked },
                audioTarget: audioTarget,
                notifier: SystemRecordingNotifier()
            )
        }
        coordinator = recordingCoordinator
        importer = MainActor.assumeIsolated {
            MediaImporter(
                library: recordingLibrary,
                makeFinalTranscription: makeFinalTranscription,
                makeSpeakerSeparation: {
                    proEntitlements.allows(.speakerSeparation) ? makeSpeakerSeparation() : .trackBased
                },
                makeNoteBuilder: makePreferredNoteBuilder,
                makeTitle: makeDetailsTitle,
                isReady: { setupFlow.isComplete && recordingLibrary.state == .unlocked }
            )
        }
        #if os(macOS)
        microphones = MainActor.assumeIsolated {
            let choice = MicrophoneChoice(
                source: CoreAudioInputDevices(),
                store: UserDefaultsMicrophoneChoiceStore(),
                meter: InputLevelMeter(input: microphone),
                isRecording: { recordingCoordinator.isCapturing }
            )
            microphone.preferredDevice = { choice.captureDeviceUID }
            return choice
        }
        #endif
        navigation = MainActor.assumeIsolated {
            let navigation = LibraryNavigation()
            #if DEBUG
            if let fixture = UITestLaunch.handedOverFixture { navigation.handOver(fixture) }
            #endif
            return navigation
        }
        let memoryExtraction = MainActor.assumeIsolated {
            MemoryExtraction(library: recordingLibrary) {
                LocalModelExtractor.canRun && memoryInstaller.state == .installed ? memoryExtractor : nil
            }
        }
        extraction = memoryExtraction
        let appLock = lock
        preferencesExporter = MainActor.assumeIsolated {
            #if os(macOS)
            PreferencesExporter(
                library: recordingLibrary,
                appLock: appLock,
                automaticRecording: UserDefaultsCallAppAllowList(),
                meetingSites: UserDefaultsMeetingSiteAllowList(),
                mediaHint: UserDefaultsMediaHintPreferencesStore(),
                microphone: UserDefaultsMicrophoneChoiceStore(),
                shortcut: UserDefaultsShortcutStore()
            )
            #else
            PreferencesExporter(library: recordingLibrary, appLock: appLock)
            #endif
        }
        Task { @MainActor in
            await developer.start()
            await Perf.trace("launch.unlock") { await recordingLibrary.unlock() }
            memoryExtraction.start()
            await proEntitlements.refresh()
            await syncEngine.syncIfEnabled()
            await recordingCoordinator.finishInterruptedProcessing()
            let titleTier = FoundationModelTitle.isAvailable ? "apple-1"
                : memoryInstaller.state == .installed ? "mlx-1" : "extractive-1"
            await Perf.trace("launch.retitle") {
                await recordingCoordinator.retitleAutomaticTitles(tier: titleTier, ledger: UserDefaultsRetitleLedger())
            }
        }
        #if os(macOS)
        shortcut = MainActor.assumeIsolated {
            RecordingShortcut(
                registrar: GlobalRecordingShortcut(),
                system: CarbonSystemShortcuts(),
                store: UserDefaultsShortcutStore()
            ) {
                Task { await recordingCoordinator.toggle() }
            }
        }
        login = MainActor.assumeIsolated {
            let login = LaunchAtLogin(service: MainAppLoginItem())
            LaunchAtLoginDefault.apply(to: login, setupComplete: setupFlow.isComplete)
            return login
        }
        mediaHint = MainActor.assumeIsolated { MediaPlaybackHint(source: CoreAudioActivitySource()) }
        #endif

        MainActor.assumeIsolated {
            StillIntentEnvironment.shared.install(library: recordingLibrary, coordinator: recordingCoordinator)
        }

        #if os(macOS)
        automatic = MainActor.assumeIsolated {
            AutomaticRecording(
                coordinator: recordingCoordinator,
                watcher: CallActivityWatcher(),
                allowList: UserDefaultsCallAppAllowList(),
                meetingEvidence: { date in
                    await CalendarContext(source: EventKitCalendarSource()).suggestion(at: date) != nil
                }
            )
        }
        browser = MainActor.assumeIsolated {
            let bridge = BrowserMeetingBridge(
                coordinator: recordingCoordinator,
                allowList: UserDefaultsMeetingSiteAllowList()
            )
            bridge.listenForExtensions()
            return bridge
        }
        aiTools = MainActor.assumeIsolated {
            let access = MCPAccess(
                settings: UserDefaultsMCPAccessSettings(),
                source: LibraryMeetingSource(library: recordingLibrary)
            )
            #if DEBUG
            if UITestLaunch.allowsAITools { access.enable() }
            #endif
            access.startIfEnabled()
            return access
        }
        chromium = MainActor.assumeIsolated {
            let connections = ChromiumConnections(
                registry: NativeMessagingHostInstaller(),
                store: UserDefaultsChromiumBrowserStore()
            )
            connections.refresh()
            return connections
        }
        let reloadLiveSettings: @MainActor @Sendable () -> Void = { [automatic, microphones, shortcut] in
            automatic.reload()
            microphones.reload()
            shortcut.reload()
        }
        #endif
        preferencesImporter = MainActor.assumeIsolated {
            #if os(macOS)
            PreferencesImporter(
                library: recordingLibrary,
                appLock: appLock,
                automaticRecording: UserDefaultsCallAppAllowList(),
                meetingSites: UserDefaultsMeetingSiteAllowList(),
                mediaHint: UserDefaultsMediaHintPreferencesStore(),
                microphone: UserDefaultsMicrophoneChoiceStore(),
                shortcut: UserDefaultsShortcutStore(),
                afterApply: reloadLiveSettings
            )
            #else
            PreferencesImporter(library: recordingLibrary, appLock: appLock)
            #endif
        }
        Perf.end(launch)
    }

    var body: some Scene {
        #if os(macOS)
        Window("Still", id: Self.libraryWindowID) {
            libraryView
        }
        .defaultSize(width: 980, height: 680)
        .onChange(of: scenePhase) { _, phase in diagnostics.developer.sceneBecame(String(describing: phase)) }
        .commands {
            CommandGroup(after: .newItem) {
                MediaImportCommand(importer: importer, navigation: navigation)
            }
        }
        .defaultLaunchBehavior(.presented)

        Settings {
            LockGate(lock: lock, coordinator: coordinator) {
                SettingsView(
                    library: library,
                    models: models,
                    entitlements: entitlements,
                    sync: sync,
                    diagnostics: diagnostics,
                    setup: setup,
                    lock: lock,
                    preferences: preferences,
                    preferencesExporter: preferencesExporter,
                    preferencesImporter: preferencesImporter,
                    automatic: automatic,
                    browser: browser,
                    aiTools: aiTools,
                    chromium: chromium,
                    microphones: microphones,
                    shortcut: shortcut,
                    login: login,
                    mediaHint: mediaHint
                )
                .perfScreen("settings")
            }
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            RecordingMenuBarPanel(
                coordinator: coordinator,
                library: library,
                automatic: automatic,
                microphones: microphones,
                navigation: navigation,
                lock: lock,
                shortcut: shortcut,
                hint: mediaHint,
                quit: { [presence] in presence.quitCompletely() }
            )
            .stillAppearance(preferences)
        } label: {
            RecordingMenuBarLabel(coordinator: coordinator, hint: mediaHint, automatic: automatic)
                .modifier(LibraryWindowOpenerInstaller(presence: presence))
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            libraryView
                .onOpenURL { navigation.handOver($0) }
        }
        .onChange(of: scenePhase) { _, phase in diagnostics.developer.sceneBecame(String(describing: phase)) }
        #endif
    }

    private var libraryView: some View {
        LockGate(lock: lock, coordinator: coordinator) {
            LibraryView(
                library: library,
                models: models,
                entitlements: entitlements,
                coordinator: coordinator,
                importer: importer,
                setup: setup,
                sync: sync,
                diagnostics: diagnostics,
                lock: lock,
                extraction: extraction,
                preferences: preferences,
                preferencesExporter: preferencesExporter,
                preferencesImporter: preferencesImporter,
                navigation: navigation
            )
        }
        .stillAppearance(preferences)
        .onAppear { [developer = diagnostics.developer] in developer.firstFrame() }
        #if os(macOS)
        .onChange(of: setup.isComplete) { _, complete in
            LaunchAtLoginDefault.apply(to: login, setupComplete: complete)
        }
        #endif
    }
}
