import SwiftData
import SwiftUI

@main
struct StillApp: App {
    private let library: Library
    private let modelInstaller: ModelPackInstaller

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

        let supportRoot = URL.applicationSupportDirectory.appending(path: "Still", directoryHint: .isDirectory)

        modelInstaller = MainActor.assumeIsolated {
            ModelPackInstaller(
                pack: ModelCatalog.parakeetV3,
                root: supportRoot.appending(path: "Models", directoryHint: .isDirectory),
                downloader: URLSessionModelFileDownloader()
            )
        }

        library = MainActor.assumeIsolated {
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
                            MicrophoneRecorder(root: audioRoot, cipher: LibraryCipher(key: key))
                        }
                    }
                )
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library, modelInstaller: modelInstaller)
        }

        #if os(macOS)
        .defaultSize(width: 980, height: 680)
        #endif
    }
}
