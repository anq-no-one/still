import Foundation
import Testing
@testable import Still

@MainActor
struct EntitlementsTests {
    @Test
    func aPurchaseUnlocksEveryProCapability() async {
        let source = FakeEntitlementSource()
        source.purchaseResult = .success(.pro)
        let entitlements = Entitlements(source: source, cache: MemoryEntitlementCache())

        await entitlements.purchase()

        #expect(entitlements.isPro)
        #expect(ProCapability.allCases.allSatisfy(entitlements.allows))
    }

    @Test
    func aPendingPurchaseIsStillPending() async {
        let source = FakeEntitlementSource()
        source.purchaseResult = .success(.pending)
        let entitlements = Entitlements(source: source, cache: MemoryEntitlementCache())

        await entitlements.purchase()

        #expect(entitlements.status == .pending)
        #expect(!entitlements.isPro)
    }

    @Test
    func everyCapabilityIsFreeForNow() {
        let entitlements = Entitlements(source: FakeEntitlementSource(), cache: MemoryEntitlementCache())

        #expect(!entitlements.isPro)
        #expect(ProCapability.allCases.allSatisfy(entitlements.allows))
    }

    @Test
    func cancellingLeavesTheUserOnFreeWithoutAnError() async {
        let source = FakeEntitlementSource()
        source.purchaseResult = .success(.free)
        let entitlements = Entitlements(source: source, cache: MemoryEntitlementCache())

        await entitlements.purchase()

        #expect(entitlements.status == .free)
        #expect(!entitlements.storeUnavailable)
    }

    @Test
    func arefundRemovesProOnTheNextRefresh() async {
        let cache = MemoryEntitlementCache()
        cache.save(.pro)
        let source = FakeEntitlementSource()
        source.currentResult = .success(.free)
        let entitlements = Entitlements(source: source, cache: cache)

        await entitlements.refresh()

        #expect(!entitlements.isPro)
        #expect(cache.load() == .free)
    }

    @Test
    func restoringReturnsAPurchaseMadeOnAnotherDevice() async {
        let source = FakeEntitlementSource()
        source.restoreResult = .success(.pro)
        let entitlements = Entitlements(source: source, cache: MemoryEntitlementCache())

        await entitlements.restore()

        #expect(entitlements.isPro)
    }

    @Test
    func anUnavailableStoreKeepsTheCachedPurchase() async {
        let cache = MemoryEntitlementCache()
        cache.save(.pro)
        let source = FakeEntitlementSource()
        source.currentResult = .failure(StoreUnavailable())
        let entitlements = Entitlements(source: source, cache: cache)

        await entitlements.refresh()

        #expect(entitlements.isPro)
        #expect(entitlements.storeUnavailable)
    }

    @Test
    func anApprovalArrivingLaterUnlocksProWithoutAsking() async {
        let source = FakeEntitlementSource()
        source.purchaseResult = .success(.pending)
        let cache = MemoryEntitlementCache()
        let entitlements = Entitlements(source: source, cache: cache)

        await entitlements.purchase()

        #expect(entitlements.status == .pending)

        source.reportFromStore(.pro)

        #expect(entitlements.isPro)
        #expect(cache.load() == .pro)
    }

    @Test
    func aRefundReportedByTheStoreTakesProAway() async {
        let source = FakeEntitlementSource()
        source.purchaseResult = .success(.pro)
        let entitlements = Entitlements(source: source, cache: MemoryEntitlementCache())
        await entitlements.purchase()

        source.reportFromStore(.free)

        #expect(!entitlements.isPro)
    }

    @Test
    func freeRecordingSurvivesAnUnavailableStore() async {
        let source = FakeEntitlementSource()
        source.currentResult = .failure(StoreUnavailable())
        let entitlements = Entitlements(source: source, cache: MemoryEntitlementCache())

        await entitlements.refresh()

        #expect(entitlements.status == .free)
        #expect(!entitlements.isPro)
    }
}

struct StoreUnavailable: Error {}

@MainActor
final class FakeEntitlementSource: EntitlementSource {
    var currentResult: Result<EntitlementStatus, Error> = .success(.free)
    var purchaseResult: Result<EntitlementStatus, Error> = .success(.free)
    var restoreResult: Result<EntitlementStatus, Error> = .success(.free)
    private var onChange: (@MainActor (EntitlementStatus) -> Void)?

    func observeChanges(_ onChange: @escaping @MainActor (EntitlementStatus) -> Void) {
        self.onChange = onChange
    }

    /// Stands in for Ask to Buy clearing, or a purchase made elsewhere.
    func reportFromStore(_ status: EntitlementStatus) {
        onChange?(status)
    }

    func current() async throws -> EntitlementStatus { try currentResult.get() }
    func purchase() async throws -> EntitlementStatus { try purchaseResult.get() }
    func restore() async throws -> EntitlementStatus { try restoreResult.get() }
}

final class MemoryEntitlementCache: EntitlementCache, @unchecked Sendable {
    private var stored: EntitlementStatus?

    func load() -> EntitlementStatus? { stored }
    func save(_ status: EntitlementStatus) { stored = status }
}
