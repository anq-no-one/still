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

/// TestFlight and the App Store ship the same binary, so the channel is read
/// at run time from the signed app transaction rather than compiled in. The
/// last answer is kept per build number for launches where StoreKit cannot
/// answer.
enum BuildChannelResolver {
    private static let cacheKey = "still.developer.buildChannel"

    static func resolve(defaults: UserDefaults = .standard) async -> BuildChannel {
        #if DEBUG
        return .debug
        #else
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
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
