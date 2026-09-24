import SwiftData
import SwiftUI

@main
struct StillApp: App {
    private let library: Library
    private let models: ModelInstallers
    private let entitlements: Entitlements
    private let coordinator: RecordingCoordinator
    private let setup: SetupFlow
    private let sync: SyncEngine
    private let diagnostics: Diagnostics
    #if os(macOS)
    private let automatic: AutomaticRecording
    private let browser: BrowserMeetingBridge
    #endif

    private let navigation: LibraryNavigation
    #if os(macOS)
    private let shortcut: GlobalRecordingShortcut
    @NSApplicationDelegateAdaptor private var reopener: LibraryWindowReopener
    #endif

    static let libraryWindowID = "library"

    init() {
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
                for: EncryptedRecording.self, EncryptedProject.self,
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
                    downloader: URLSessionModelFileDownloader()
                ),
                speakers: ModelPackInstaller(
                    pack: ModelCatalog.speakerSeparation,
                    root: modelRoot,
                    downloader: URLSessionModelFileDownloader()
                )
            )
        }
        models = installers
        let speech = ParakeetEngine(pack: ModelCatalog.parakeetV3, root: modelRoot)
        let installer = installers.transcription

        let recordingLibrary = MainActor.assumeIsolated {
            Library(
                keyRing: LibraryKeyRing(source: KeychainDeviceKeySource()),
                services: LibraryServices(
                    audioRoot: audioRoot,
                    settingsFile: supportRoot.appending(path: "Library.settings"),
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
                                scope: { audioTarget.scope }
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
                    }
                ),
                selectionStore: UserDefaultsProjectSelectionStore()
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
        library = recordingLibrary
        diagnostics = MainActor.assumeIsolated {
            Diagnostics(settings: UserDefaultsDiagnosticsSettings(), sink: NoDiagnosticsSink())
        }

        let syncEngine = MainActor.assumeIsolated {
            SyncEngine(
                library: recordingLibrary,
                transport: CloudKitSyncTransport(),
                settings: UserDefaultsSyncSettings()
            )
        }
        sync = syncEngine
        let recordingCoordinator = MainActor.assumeIsolated {
            RecordingCoordinator(
                library: recordingLibrary,
                entitlements: proEntitlements,
                makeSession: { LiveTranscriber(input: microphone, systemAudio: systemAudio, engine: speech) },
                makeFinalTranscription: { FinalTranscription(transcriber: ParakeetOfflineTranscriber(engine: speech)) },
                makeSpeakerSeparation: {
                    SpeakerSeparation(
                        diarizer: FluidSpeakerDiarizer(pack: ModelCatalog.speakerSeparation, root: modelRoot),
                        voiceprints: FluidVoiceprintExtractor(pack: ModelCatalog.speakerSeparation, root: modelRoot)
                    )
                },
                expectedParticipants: { date in
                    await CalendarContext(source: EventKitCalendarSource()).suggestion(at: date)?.participants ?? []
                },
                isReady: { setupFlow.isComplete && recordingLibrary.state == .unlocked },
                audioTarget: audioTarget
            )
        }
        coordinator = recordingCoordinator
        navigation = MainActor.assumeIsolated { LibraryNavigation() }
        Task { @MainActor in
            await recordingLibrary.unlock()
            await proEntitlements.refresh()
            await syncEngine.syncIfEnabled()
        }
        #if os(macOS)
        shortcut = MainActor.assumeIsolated {
            GlobalRecordingShortcut { Task { await recordingCoordinator.toggle() } }
        }
        #endif

        MainActor.assumeIsolated {
            StillIntentEnvironment.shared.install(library: recordingLibrary, coordinator: recordingCoordinator)
        }

        #if os(macOS)
        automatic = MainActor.assumeIsolated {
            AutomaticRecording(
                coordinator: recordingCoordinator,
                watcher: CallActivityWatcher(),
                allowList: UserDefaultsCallAppAllowList()
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
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        Window("Still", id: Self.libraryWindowID) {
            libraryView
        }
        .defaultSize(width: 980, height: 680)
        .defaultLaunchBehavior(.presented)

        Settings {
            SettingsView(
                library: library,
                models: models,
                entitlements: entitlements,
                sync: sync,
                diagnostics: diagnostics,
                automatic: automatic,
                browser: browser
            )
        }

        MenuBarExtra {
            RecordingMenuBarPanel(coordinator: coordinator, library: library, automatic: automatic, navigation: navigation)
        } label: {
            RecordingMenuBarLabel(coordinator: coordinator)
                .modifier(LibraryWindowOpenerInstaller(reopener: reopener))
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            libraryView
        }
        #endif
    }

    private var libraryView: some View {
        LibraryView(
            library: library,
            models: models,
            entitlements: entitlements,
            coordinator: coordinator,
            setup: setup,
            sync: sync,
            diagnostics: diagnostics,
            navigation: navigation
        )
    }
}
