import SwiftData
import SwiftUI

@main
struct StillApp: App {
    private let library: Library

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: EncryptedRecording.self)
        } catch {
            fatalError("Unable to open the local Library store.")
        }

        let context = ModelContext(container)
        library = Library(
            keyRing: LibraryKeyRing(source: KeychainDeviceKeySource()),
            makeRepository: { key in
                MainActor.assumeIsolated {
                    EncryptedRecordingRepository(context: context, key: key)
                }
            }
        )
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library)
        }

        #if os(macOS)
        .defaultSize(width: 980, height: 680)
        #endif
    }
}
