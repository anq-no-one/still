import Foundation
import Testing
@testable import Still

struct SystemAudioScopeTests {
    private let zoom = CallApp.known.first { $0.bundleID == "us.zoom.xos" }!
    private let faceTime = CallApp.known.first { $0.bundleID == "com.apple.FaceTime" }!

    @Test
    func aManualRecordingHearsCallAppsAndBrowsersButNotMusic() {
        let scope = SystemAudioScope.callApps

        #expect(scope.includes("us.zoom.xos"))
        #expect(scope.includes("com.tinyspeck.slackmacgap.helper"))
        #expect(scope.includes("com.google.Chrome.helper"))
        #expect(!scope.includes("com.apple.Music"))
        #expect(!scope.includes("com.spotify.client"))
        #expect(!scope.includes("com.apple.QuickTimePlayerX"))
    }

    @Test
    func anAutomaticCallHearsOnlyThatApp() {
        let scope = SystemAudioScope.app(zoom)

        #expect(scope.includes("us.zoom.xos"))
        #expect(!scope.includes("com.google.Chrome"))
        #expect(!scope.includes("com.tinyspeck.slackmacgap"))
        #expect(!scope.includes("com.spotify.client"))
    }

    @Test
    func aFaceTimeCallAlsoHearsTheConferencingService() {
        #expect(SystemAudioScope.app(faceTime).includes("com.apple.avconferenced"))
    }

    @Test
    func aBrowserMeetingHearsOnlyTheBrowserThatHostsIt() {
        let scope = SystemAudioScope.browser("com.google.Chrome")

        #expect(scope.includes("com.google.Chrome.helper"))
        #expect(!scope.includes("com.apple.Safari"))
        #expect(!scope.includes("com.spotify.client"))
    }

    @Test
    func anUnknownBrowserFallsBackToEveryBrowserButNothingElse() {
        let scope = SystemAudioScope.browser(nil)

        #expect(scope.includes("com.apple.Safari"))
        #expect(scope.includes("com.brave.Browser"))
        #expect(!scope.includes("us.zoom.xos"))
        #expect(!scope.includes("com.apple.Music"))
    }

    @Test
    func aPrefixThatIsNotASubIdentifierDoesNotMatch() {
        #expect(!SystemAudioScope.app(zoom).includes("us.zoom.xosfake"))
    }
}
