import Foundation

struct WebBrowser: Identifiable, Equatable, Sendable {
    var id: String { bundleID }

    let bundleID: String
    let name: String
    let nativeMessagingHostsPath: String?

    var isChromium: Bool {
        nativeMessagingHostsPath != nil
    }

    static let safari = WebBrowser(bundleID: "com.apple.Safari", name: "Safari", nativeMessagingHostsPath: nil)

    static let chromium: [WebBrowser] = [
        WebBrowser(
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            nativeMessagingHostsPath: "Library/Application Support/Google/Chrome/NativeMessagingHosts"
        ),
        WebBrowser(
            bundleID: "com.microsoft.edgemac",
            name: "Microsoft Edge",
            nativeMessagingHostsPath: "Library/Application Support/Microsoft Edge/NativeMessagingHosts"
        ),
        WebBrowser(
            bundleID: "com.brave.Browser",
            name: "Brave",
            nativeMessagingHostsPath: "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
        ),
        WebBrowser(
            bundleID: "company.thebrowser.Browser",
            name: "Arc",
            nativeMessagingHostsPath: "Library/Application Support/Arc/User Data/NativeMessagingHosts"
        ),
    ]

    static let all: [WebBrowser] = [safari] + chromium + [
        WebBrowser(bundleID: "org.mozilla.firefox", name: "Firefox", nativeMessagingHostsPath: nil),
    ]
}
