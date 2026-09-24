#if os(macOS)
import Foundation
import Observation

enum ChromiumExtensionIdentity {
    static let developmentID = "bjhafjfdnikjoagaebbbnfimjeoaljbn"
    static let storeIDs: [String] = []

    static var allIDs: [String] {
        [developmentID] + storeIDs
    }
}

struct NativeMessagingHostManifest: Codable, Equatable {
    static let hostName = "com.andrii.still.meetings"
    static let executableName = "StillNativeHost"

    let name: String
    let description: String
    let path: String
    let type: String
    let allowedOrigins: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case path
        case type
        case allowedOrigins = "allowed_origins"
    }

    init(hostExecutable: URL, extensionIDs: [String]) {
        name = Self.hostName
        description = "Tells Still when an approved meeting starts and ends."
        path = hostExecutable.path(percentEncoded: false)
        type = "stdio"
        allowedOrigins = extensionIDs.map { "chrome-extension://\($0)/" }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

protocol NativeMessagingHostRegistry {
    func install(for browser: WebBrowser) throws
    func remove(for browser: WebBrowser) throws
}

struct NativeMessagingHostInstaller: NativeMessagingHostRegistry {
    let home: URL
    let hostExecutable: URL
    let extensionIDs: [String]

    init(
        home: URL = Self.userHome,
        hostExecutable: URL = Self.bundledHost,
        extensionIDs: [String] = ChromiumExtensionIdentity.allIDs
    ) {
        self.home = home
        self.hostExecutable = hostExecutable
        self.extensionIDs = extensionIDs
    }

    static var userHome: URL {
        guard let directory = getpwuid(getuid())?.pointee.pw_dir else { return URL.homeDirectory }
        return URL(filePath: String(cString: directory), directoryHint: .isDirectory)
    }

    static var bundledHost: URL {
        Bundle.main.url(forAuxiliaryExecutable: NativeMessagingHostManifest.executableName)
            ?? Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(NativeMessagingHostManifest.executableName)")
    }

    func manifestURL(for browser: WebBrowser) -> URL? {
        browser.nativeMessagingHostsPath.map {
            home.appending(path: $0, directoryHint: .isDirectory)
                .appending(path: "\(NativeMessagingHostManifest.hostName).json")
        }
    }

    func install(for browser: WebBrowser) throws {
        guard let url = manifestURL(for: browser) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try NativeMessagingHostManifest(hostExecutable: hostExecutable, extensionIDs: extensionIDs)
            .encoded()
            .write(to: url, options: .atomic)
    }

    func remove(for browser: WebBrowser) throws {
        guard let url = manifestURL(for: browser), FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        else { return }
        try FileManager.default.removeItem(at: url)
    }
}

protocol ChromiumBrowserStore: Sendable {
    func enabledBrowsers() -> Set<String>
    func setEnabled(_ enabled: Bool, forBundleID bundleID: String)
}

struct UserDefaultsChromiumBrowserStore: ChromiumBrowserStore, @unchecked Sendable {
    private let key = "still.chromiumBrowsers.enabled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func enabledBrowsers() -> Set<String> {
        Set(defaults.array(forKey: key) as? [String] ?? [])
    }

    func setEnabled(_ enabled: Bool, forBundleID bundleID: String) {
        var current = enabledBrowsers()
        if enabled {
            current.insert(bundleID)
        } else {
            current.remove(bundleID)
        }
        defaults.set(Array(current).sorted(), forKey: key)
    }
}

@MainActor
@Observable
final class ChromiumConnections {
    struct Connection: Identifiable, Equatable {
        var id: String { browser.bundleID }

        let browser: WebBrowser
        let isEnabled: Bool
    }

    private let registry: NativeMessagingHostRegistry
    private let store: ChromiumBrowserStore

    private(set) var connections: [Connection] = []
    private(set) var failure: String?

    init(registry: NativeMessagingHostRegistry, store: ChromiumBrowserStore) {
        self.registry = registry
        self.store = store
        reload()
    }

    func setEnabled(_ enabled: Bool, for browser: WebBrowser) {
        do {
            if enabled {
                try registry.install(for: browser)
            } else {
                try registry.remove(for: browser)
            }
            store.setEnabled(enabled, forBundleID: browser.bundleID)
            failure = nil
        } catch {
            failure = String(localized: "Still could not connect \(browser.name). Try again, or turn the browser off and on.")
        }
        reload()
    }

    func refresh() {
        let enabled = store.enabledBrowsers()
        for browser in WebBrowser.chromium where enabled.contains(browser.bundleID) {
            try? registry.install(for: browser)
        }
    }

    private func reload() {
        let enabled = store.enabledBrowsers()
        connections = WebBrowser.chromium.map { Connection(browser: $0, isEnabled: enabled.contains($0.bundleID)) }
    }
}
#endif
