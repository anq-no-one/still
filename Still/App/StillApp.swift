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

    #if os(macOS)
    @State private var shortcut: GlobalRecordingShortcut?
    #endif

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: EncryptedRecording.self)
        } catch {
            fatalError("Unable to open the local Library store.")
        }

        let context = ModelContext(container)
        let audioRoot = URL.applicationSupportDirectory
            .appending(path: "Still/Audio", directoryHint: .isDirectory)

        let proEntitlements = MainActor.assumeIsolated { Entitlements(source: StoreKitEntitlementSource()) }
        entitlements = proEntitlements

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
                                capturesSystemAudio: { proEntitlements.allows(.macSystemAudio) }
                            )
                            #else
                            MicrophoneRecorder(root: audioRoot, cipher: LibraryCipher(key: key))
                            #endif
                        }
                    }
                )
            )
        }

        setup = MainActor.assumeIsolated {
            SetupFlow(
                store: UserDefaultsSetupProgressStore(),
                microphone: SystemMicrophoneAccess()
            )
        }
        library = recordingLibrary
        sync = MainActor.assumeIsolated {
            SyncEngine(
                library: recordingLibrary,
                transport: CloudKitSyncTransport(),
                settings: UserDefaultsSyncSettings()
            )
        }
        coordinator = MainActor.assumeIsolated {
            RecordingCoordinator(library: recordingLibrary, entitlements: proEntitlements)
        }
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(
                library: library,
                modelInstaller: modelInstaller,
                entitlements: entitlements,
                coordinator: coordinator,
                setup: setup,
                sync: sync
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
        MenuBarExtra {
            RecordingMenuBarContent(coordinator: coordinator)
        } label: {
            RecordingMenuBarLabel(coordinator: coordinator)
        }
        #endif
    }
}
