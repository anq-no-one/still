import Foundation
import StoreKit

enum BuildChannel: String, Codable, Sendable {
    case debug
    case testFlight
    case appStore
    case unknown

    var collectsDeveloperDiagnostics: Bool {
        self == .debug || self == .testFlight
    }
}

/// The store writes its environment into the receipt it installs beside the
/// app, so a TestFlight install is known offline, before StoreKit answers.
enum ReceiptEnvironment {
    private static let environments: [(name: String, channel: BuildChannel)] = [
        ("ProductionSandbox", .testFlight),
        ("Production", .appStore),
    ]

    static func channel(receipt: Data) -> BuildChannel? {
        for environment in environments {
            let value = Array(environment.name.utf8)
            let attribute: [UInt8] = [0x02, 0x01, 0x00, 0x02, 0x01, 0x01, 0x04, UInt8(value.count + 2), 0x0C, UInt8(value.count)] + value
            if receipt.range(of: Data(attribute)) != nil { return environment.channel }
        }
        return nil
    }

    static func channel(receipts: [URL]) -> BuildChannel? {
        for url in receipts {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let channel = channel(receipt: data) { return channel }
            if url.lastPathComponent == "sandboxReceipt" { return .testFlight }
        }
        return nil
    }

    static var installedReceipts: [URL] {
        #if os(macOS)
        [Bundle.main.bundleURL.appending(path: "Contents/_MASReceipt/receipt")]
        #else
        ["sandboxReceipt", "receipt"].map { Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "StoreKit/\($0)") }
        #endif
    }
}

/// TestFlight and the App Store ship the same binary, so the channel is read
/// at run time from the store receipt, then from the signed app transaction,
/// rather than compiled in. The last answer is kept per build number for
/// launches where neither can answer.
enum BuildChannelResolver {
    private static let cacheKey = "still.developer.buildChannel"

    static func resolve(defaults: UserDefaults = .standard) async -> BuildChannel {
        #if DEBUG
        return .debug
        #else
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        if let channel = ReceiptEnvironment.channel(receipts: ReceiptEnvironment.installedReceipts) {
            defaults.set([build: channel.rawValue], forKey: cacheKey)
            return channel
        }
        let cached = (defaults.dictionary(forKey: cacheKey)?[build] as? String).flatMap(BuildChannel.init(rawValue:))
        guard let result = try? await AppTransaction.shared else { return cached ?? .unknown }

        let transaction: AppTransaction = switch result {
        case .verified(let transaction), .unverified(let transaction, _): transaction
        }
        let channel: BuildChannel = switch transaction.environment {
        case .production: .appStore
        case .sandbox: .testFlight
        case .xcode: .debug
        default: .unknown
        }
        defaults.set([build: channel.rawValue], forKey: cacheKey)
        return channel
        #endif
    }
}
