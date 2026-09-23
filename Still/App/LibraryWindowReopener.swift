#if os(macOS)
import AppKit
import SwiftUI

/// SwiftUI leaves a closed `Window` closed when the Dock icon is clicked, so the
/// app delegate asks for it again the way every document-free Mac app does.
@MainActor
final class LibraryWindowReopener: NSObject, NSApplicationDelegate {
    var open: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            open?()
        }
        return true
    }
}

struct LibraryWindowOpenerInstaller: ViewModifier {
    let reopener: LibraryWindowReopener
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            reopener.open = { openWindow(id: StillApp.libraryWindowID) }
        }
    }
}
#endif
