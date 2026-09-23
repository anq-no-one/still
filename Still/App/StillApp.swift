import SwiftData
import SwiftUI

@main
struct StillApp: App {
    private let library: Library
    private let modelInstaller: ModelPackInstaller
    private let entitlements: Entitlements
    private let coordinator: RecordingCoordinator
    private let setup: SetupFlow
    private let sync: SyncEngine
    private let diagnostics: Diagnostics
    #if os(macOS)
    private let automatic: AutomaticRecording
    private let browser: BrowserMeetingBridge
    #endif

    #if os(macOS)
    @State private var shortcut: GlobalRecordingShortcut?
    #endif

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
                for: EncryptedRecording.self,
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

        let supportRoot = URL.applicationSupportDirectory.appending(path: "Still", directoryHint: .isDirectory)

        modelInstaller = MainActor.assumeIsolated {
            ModelPackInstaller(
                pack: ModelCatalog.parakeetV3,
                root: supportRoot.appending(path: "Models", directoryHint: .isDirectory),
                downloader: URLSessionModelFileDownloader()
            )
        }

        let recordingLibrary = MainActor.assumeIsolated {
            Library(
                keyRing: LibraryKeyRing(source: KeychainDeviceKeySource()),
                services: LibraryServices(
                    audioRoot: audioRoot,
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
                                capturesSystemAudio: { proEntitlements.allows(.macSystemAudio) }
                            )
                            #else
                            MicrophoneRecorder(root: audioRoot, cipher: LibraryCipher(key: key), input: microphone)
                            #endif
                        }
                    }
                )
            )
        }

        setup = MainActor.assumeIsolated {
            SetupFlow(
                store: UserDefaultsSetupProgressStore(),
                microphone: SystemMicrophoneAccess(),
                offersPro: !Entitlements.everythingIsFree
            )
        }
        library = recordingLibrary
        diagnostics = MainActor.assumeIsolated {
            Diagnostics(settings: UserDefaultsDiagnosticsSettings(), sink: NoDiagnosticsSink())
        }

        sync = MainActor.assumeIsolated {
            SyncEngine(
                library: recordingLibrary,
                transport: CloudKitSyncTransport(),
                settings: UserDefaultsSyncSettings()
            )
        }
        let recordingCoordinator = MainActor.assumeIsolated {
            RecordingCoordinator(
                library: recordingLibrary,
                entitlements: proEntitlements,
                makeSession: { LiveTranscriber(input: microphone) }
            )
        }
        coordinator = recordingCoordinator

        MainActor.assumeIsolated {
            StillIntentEnvironment.shared.install(library: recordingLibrary, coordinator: recordingCoordinator)
        }

        #if os(macOS)
        automatic = MainActor.assumeIsolated {
            AutomaticRecording(
                coordinator: recordingCoordinator,
                watcher: WorkspaceCallAppWatcher(),
                allowList: UserDefaultsCallAppAllowList()
            )
        }
        browser = MainActor.assumeIsolated {
            BrowserMeetingBridge(
                coordinator: recordingCoordinator,
                allowList: UserDefaultsMeetingSiteAllowList()
            )
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(
                library: library,
                modelInstaller: modelInstaller,
                entitlements: entitlements,
                coordinator: coordinator,
                setup: setup,
                sync: sync,
                diagnostics: diagnostics
            )
            #if os(macOS)
            .task {
                guard shortcut == nil else { return }
                let coordinator = coordinator
                shortcut = GlobalRecordingShortcut { Task { await coordinator.toggle() } }
            }
            #endif
        }

        #if os(macOS)
        .defaultSize(width: 980, height: 680)
        #endif

        #if os(macOS)
        Settings {
            SettingsView(
                library: library,
                modelInstaller: modelInstaller,
                entitlements: entitlements,
                sync: sync,
                diagnostics: diagnostics,
                automatic: automatic,
                browser: browser
            )
        }

        MenuBarExtra {
            RecordingMenuBarContent(coordinator: coordinator)
        } label: {
            RecordingMenuBarLabel(coordinator: coordinator)
        }
        #endif
    }
}
