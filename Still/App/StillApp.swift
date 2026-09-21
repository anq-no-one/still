import SwiftData
import SwiftUI

@main
struct StillApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: Meeting.self)
        } catch {
            fatalError("Unable to open the local meeting library: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MeetingLibraryView()
        }
        .modelContainer(modelContainer)

        #if os(macOS)
        .defaultSize(width: 980, height: 680)
        #endif
    }
}

