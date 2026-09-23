#if os(macOS)
import AppKit
import Testing
@testable import Still

@MainActor
struct LibraryWindowReopenerTests {
    @Test
    func clickingTheDockIconWithNoWindowOpensTheLibrary() {
        let reopener = LibraryWindowReopener()
        let opened = Flag()
        reopener.open = { opened.raise() }

        _ = reopener.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)

        #expect(opened.isRaised)
    }

    @Test
    func clickingTheDockIconWithAWindowLeavesItAlone() {
        let reopener = LibraryWindowReopener()
        let opened = Flag()
        reopener.open = { opened.raise() }

        _ = reopener.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)

        #expect(!opened.isRaised)
    }
}
#endif
