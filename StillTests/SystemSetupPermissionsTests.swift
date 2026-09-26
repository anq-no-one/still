import Testing
@testable import Still

@MainActor
struct SystemSetupPermissionsTests {
    @Test
    func relaunchWaitsForOldInstanceBeforeOpening() {
        let command = SystemSetupPermissions.relaunchCommand(processID: 1234, bundlePath: "/Applications/Still.app")

        let wait = command.range(of: "kill -0 1234")!
        let open = command.range(of: "/usr/bin/open")!
        #expect(wait.lowerBound < open.lowerBound)
    }

    @Test
    func relaunchWaitsABoundedTime() {
        let command = SystemSetupPermissions.relaunchCommand(processID: 1234, bundlePath: "/Applications/Still.app")

        #expect(command.contains("-lt 100"))
    }

    @Test
    func relaunchOpensSingleInstance() {
        let command = SystemSetupPermissions.relaunchCommand(processID: 1234, bundlePath: "/Applications/Still.app")

        #expect(command.contains("/usr/bin/open '/Applications/Still.app'"))
        #expect(!command.contains("-n"))
    }

    @Test
    func relaunchEscapesBundlePath() {
        let command = SystemSetupPermissions.relaunchCommand(processID: 1234, bundlePath: "/Appli'cations/Still.app")

        #expect(command.contains("/usr/bin/open '/Appli'\\''cations/Still.app'"))
    }
}
