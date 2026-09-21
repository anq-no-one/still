import Foundation
import StoreKit

@MainActor
final class StoreKitEntitlementSource: EntitlementSource {
    static let productID = "com.andrii.still.pro"

    private var updates: Task<Void, Never>?

    init(onChange: @escaping @MainActor (EntitlementStatus) -> Void = { _ in }) {
        updates = Task { [productID = Self.productID] in
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update,
                      transaction.productID == productID
                else { continue }

                await transaction.finish()
                onChange(transaction.revocationDate == nil ? .pro : .free)
            }
        }
    }

    deinit {
        updates?.cancel()
    }

    func current() async throws -> EntitlementStatus {
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  transaction.productID == Self.productID,
                  transaction.revocationDate == nil
            else { continue }

            return .pro
        }
        return .free
    }

    func purchase() async throws -> EntitlementStatus {
        guard let product = try await Product.products(for: [Self.productID]).first else {
            throw StoreKitError.unknown
        }

        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { return .free }
            await transaction.finish()
            return transaction.revocationDate == nil ? .pro : .free
        case .pending:
            return .pending
        case .userCancelled:
            return try await current()
        @unknown default:
            return try await current()
        }
    }

    func restore() async throws -> EntitlementStatus {
        try await AppStore.sync()
        return try await current()
    }
}
