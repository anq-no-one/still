import CryptoKit
import Foundation
import Testing
@testable import Still

struct NativeMessageReaderTests {
    private let started = Data(#"{"host":"meet.google.com","meetingID":"m","phase":"started","tabID":7}"#.utf8)

    @Test
    func aWholeFrameBecomesOneMessage() throws {
        var reader = NativeMessageReader()

        let messages = try reader.append(NativeMessageFrame.encode(started))

        #expect(messages == [started])
    }

    @Test
    func aFrameSplitAcrossReadsIsReassembled() throws {
        var reader = NativeMessageReader()
        let frame = NativeMessageFrame.encode(started)

        let first = try reader.append(frame.prefix(2))
        let second = try reader.append(frame.dropFirst(2).prefix(10))
        let third = try reader.append(frame.dropFirst(12))

        #expect(first.isEmpty)
        #expect(second.isEmpty)
        #expect(third == [started])
    }

    @Test
    func twoFramesInOneReadBecomeTwoMessages() throws {
        var reader = NativeMessageReader()
        let ended = Data(#"{"host":"meet.google.com","meetingID":"m","phase":"ended"}"#.utf8)

        let messages = try reader.append(NativeMessageFrame.encode(started) + NativeMessageFrame.encode(ended))

        #expect(messages == [started, ended])
    }

    @Test
    func theLengthIsLittleEndian() {
        let frame = NativeMessageFrame.encode(Data(repeating: 0x20, count: 258))

        #expect(Array(frame.prefix(4)) == [0x02, 0x01, 0x00, 0x00])
    }

    @Test
    func anOversizedFrameIsRefused() {
        var reader = NativeMessageReader()
        let length = NativeMessageFrame.maximumIncomingLength + 1
        let header = withUnsafeBytes(of: UInt32(length).littleEndian) { Data($0) }

        #expect(throws: NativeMessageReader.Failure.oversized(length)) {
            try reader.append(header)
        }
    }

    @Test
    func aDecodedFrameBecomesAMeetingEventForTheHostBrowser() throws {
        var reader = NativeMessageReader()
        let message = try #require(try reader.append(NativeMessageFrame.encode(started)).first)

        let event = BrowserMeetingSignal.event(fromExtensionMessage: message, browserBundleID: "com.google.Chrome")

        #expect(event == BrowserMeetingEvent(
            host: "meet.google.com",
            meetingID: "m",
            phase: .started,
            browserBundleID: "com.google.Chrome",
            tabID: 7
        ))
    }

    @Test
    func theAcknowledgementIsAFramedJSONObject() throws {
        var reader = NativeMessageReader()

        let reply = try #require(try reader.append(NativeMessageFrame.acknowledgement).first)

        #expect(try JSONSerialization.jsonObject(with: reply) as? [String: Bool] == ["received": true])
    }

    @Test
    func aHelperProcessIsNamedByItsBrowser() {
        #expect(WebBrowser.bundleID(owning: "com.google.Chrome.helper") == "com.google.Chrome")
        #expect(WebBrowser.bundleID(owning: "com.vivaldi.Vivaldi") == "com.vivaldi.Vivaldi")
    }
}

struct NativeMessagingHostManifestTests {
    private let host = URL(filePath: "/Applications/Still.app/Contents/MacOS/StillNativeHost")

    @Test
    func theManifestNamesTheBundledHostAndOnlyStillsExtension() throws {
        let data = try NativeMessagingHostManifest(hostExecutable: host, extensionIDs: ["abc"]).encoded()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["name"] as? String == "com.andrii.still.meetings")
        #expect(json["path"] as? String == "/Applications/Still.app/Contents/MacOS/StillNativeHost")
        #expect(json["type"] as? String == "stdio")
        #expect(json["allowed_origins"] as? [String] == ["chrome-extension://abc/"])
        #expect(Set(json.keys) == ["name", "description", "path", "type", "allowed_origins"])
    }

    @Test
    func aPathWithSpacesIsWrittenPlainly() throws {
        let spaced = URL(filePath: "/Applications/My Apps/Still.app/Contents/MacOS/StillNativeHost")

        let manifest = NativeMessagingHostManifest(hostExecutable: spaced, extensionIDs: [])

        #expect(manifest.path == "/Applications/My Apps/Still.app/Contents/MacOS/StillNativeHost")
    }

    @Test
    func theDevelopmentIDMatchesTheKeyInTheExtensionManifest() throws {
        let manifestURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "ChromiumExtension/manifest.json")
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let encodedKey = try #require(manifest["key"] as? String)
        let key = try #require(Data(base64Encoded: encodedKey))

        let id = SHA256.hash(data: key).prefix(16)
            .flatMap { [$0 >> 4, $0 & 0x0f] }
            .map { String(UnicodeScalar(UInt8(ascii: "a") + $0)) }
            .joined()

        #expect(id == ChromiumExtensionIdentity.developmentID)
    }

    @Test
    func everyChromiumBrowserHasItsOwnHostsFolder() {
        let paths = WebBrowser.chromium.compactMap(\.nativeMessagingHostsPath)

        #expect(paths.count == WebBrowser.chromium.count)
        #expect(Set(paths).count == paths.count)
        #expect(paths.allSatisfy { $0.hasSuffix("/NativeMessagingHosts") })
    }
}

struct NativeMessagingHostInstallerTests {
    private let chrome = WebBrowser.chromium.first { $0.bundleID == "com.google.Chrome" }!
    private let brave = WebBrowser.chromium.first { $0.bundleID == "com.brave.Browser" }!

    @Test
    func installingWritesTheManifestIntoThatBrowsersFolderOnly() throws {
        let scratch = try Scratch()
        let installer = makeInstaller(home: scratch.directory)

        try installer.install(for: chrome)

        let written = scratch.directory
            .appending(path: "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.andrii.still.meetings.json")
        let manifest = try JSONDecoder().decode(NativeMessagingHostManifest.self, from: Data(contentsOf: written))
        #expect(manifest.allowedOrigins == ["chrome-extension://abc/"])
        #expect(!FileManager.default.fileExists(atPath: try #require(installer.manifestURL(for: brave)).path(percentEncoded: false)))
    }

    @Test
    func removingDeletesTheManifest() throws {
        let scratch = try Scratch()
        let installer = makeInstaller(home: scratch.directory)
        try installer.install(for: chrome)

        try installer.remove(for: chrome)

        #expect(!FileManager.default.fileExists(atPath: try #require(installer.manifestURL(for: chrome)).path(percentEncoded: false)))
    }

    @Test
    func removingWhatWasNeverInstalledIsFine() throws {
        let scratch = try Scratch()

        try makeInstaller(home: scratch.directory).remove(for: brave)
    }

    @Test
    func safariNeedsNoManifest() throws {
        let scratch = try Scratch()
        let installer = makeInstaller(home: scratch.directory)

        try installer.install(for: .safari)

        #expect(installer.manifestURL(for: .safari) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.directory.path(percentEncoded: false)).isEmpty)
    }

    private func makeInstaller(home: URL) -> NativeMessagingHostInstaller {
        NativeMessagingHostInstaller(
            home: home,
            hostExecutable: URL(filePath: "/Applications/Still.app/Contents/MacOS/StillNativeHost"),
            extensionIDs: ["abc"]
        )
    }
}

@MainActor
struct ChromiumConnectionsTests {
    private let chrome = WebBrowser.chromium.first { $0.bundleID == "com.google.Chrome" }!
    private let edge = WebBrowser.chromium.first { $0.bundleID == "com.microsoft.edgemac" }!

    @Test
    func nothingIsWrittenUntilTheUserTurnsABrowserOn() {
        let registry = SpyHostRegistry()

        let connections = ChromiumConnections(registry: registry, store: MemoryChromiumBrowserStore())
        connections.refresh()

        #expect(registry.installed.isEmpty)
        #expect(connections.connections.allSatisfy { !$0.isEnabled })
    }

    @Test
    func turningABrowserOnInstallsItsHostAndRemembersIt() {
        let registry = SpyHostRegistry()
        let store = MemoryChromiumBrowserStore()
        let connections = ChromiumConnections(registry: registry, store: store)

        connections.setEnabled(true, for: chrome)

        #expect(registry.installed == [chrome.bundleID])
        #expect(store.enabledBrowsers() == [chrome.bundleID])
        #expect(connections.connections.first { $0.browser == chrome }?.isEnabled == true)
    }

    @Test
    func turningABrowserOffRemovesItsHost() {
        let registry = SpyHostRegistry()
        let store = MemoryChromiumBrowserStore()
        let connections = ChromiumConnections(registry: registry, store: store)
        connections.setEnabled(true, for: chrome)

        connections.setEnabled(false, for: chrome)

        #expect(registry.installed.isEmpty)
        #expect(store.enabledBrowsers().isEmpty)
    }

    @Test
    func aFailedInstallLeavesTheBrowserOffAndSaysSo() {
        let registry = SpyHostRegistry()
        registry.fails = true
        let connections = ChromiumConnections(registry: registry, store: MemoryChromiumBrowserStore())

        connections.setEnabled(true, for: chrome)

        #expect(connections.failure != nil)
        #expect(connections.connections.first { $0.browser == chrome }?.isEnabled == false)
    }

    @Test
    func refreshingRewritesOnlyEnabledBrowsers() {
        let registry = SpyHostRegistry()
        let store = MemoryChromiumBrowserStore()
        store.setEnabled(true, forBundleID: edge.bundleID)
        let connections = ChromiumConnections(registry: registry, store: store)

        connections.refresh()

        #expect(registry.installed == [edge.bundleID])
    }
}

final class SpyHostRegistry: NativeMessagingHostRegistry {
    struct Refused: Error {}

    private(set) var installed: Set<String> = []
    var fails = false

    func install(for browser: WebBrowser) throws {
        if fails { throw Refused() }
        installed.insert(browser.bundleID)
    }

    func remove(for browser: WebBrowser) throws {
        if fails { throw Refused() }
        installed.remove(browser.bundleID)
    }
}

final class MemoryChromiumBrowserStore: ChromiumBrowserStore, @unchecked Sendable {
    private var enabled: Set<String> = []

    func enabledBrowsers() -> Set<String> {
        enabled
    }

    func setEnabled(_ isEnabled: Bool, forBundleID bundleID: String) {
        if isEnabled {
            enabled.insert(bundleID)
        } else {
            enabled.remove(bundleID)
        }
    }
}
