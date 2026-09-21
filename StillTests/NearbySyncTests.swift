import Foundation
import Testing
@testable import Still

@MainActor
struct NearbySyncTests {
    private let peer = NearbyPeer(id: UUID(), name: "Andrii's Mac")

    @Test
    func discoversNothingUntilItIsTurnedOn() {
        let session = FakeNearbySession(peers: [peer])
        let sync = NearbySync(session: session)

        #expect(sync.state == .off)
        #expect(sync.peers.isEmpty)
        #expect(session.discoveries == 0)

        sync.enable()

        #expect(sync.state == .discovering)
        #expect(sync.peers == [peer])
    }

    @Test
    func pairingNeedsAYesOnBothDevices() {
        let session = FakeNearbySession(peers: [peer])
        let sync = NearbySync(session: session)
        sync.enable()

        sync.invite(peer)

        #expect(sync.state == .awaitingConfirmation(peer))
        #expect(!sync.isPaired)

        sync.confirm()

        #expect(!sync.isPaired)

        session.confirmFromPeer()

        #expect(sync.isPaired)
    }

    @Test
    func theOtherDeviceAloneCannotPairUs() {
        let session = FakeNearbySession(peers: [peer])
        let sync = NearbySync(session: session)
        sync.enable()
        sync.invite(peer)

        session.confirmFromPeer()

        #expect(!sync.isPaired)
        #expect(sync.state == .awaitingConfirmation(peer))
    }

    @Test
    func turningItOffStopsDiscoveryAndDropsThePairing() {
        let session = FakeNearbySession(peers: [peer])
        let sync = NearbySync(session: session)
        sync.enable()
        sync.invite(peer)
        sync.confirm()
        session.confirmFromPeer()

        sync.disable()

        #expect(sync.state == .off)
        #expect(sync.peers.isEmpty)
        #expect(session.stops == 1)
        #expect(session.disconnects == 1)
    }

    @Test
    func pairingAgainStartsFromScratch() {
        let session = FakeNearbySession(peers: [peer])
        let sync = NearbySync(session: session)
        sync.enable()
        sync.invite(peer)
        sync.confirm()
        session.confirmFromPeer()
        sync.disable()
        sync.enable()

        sync.invite(peer)

        #expect(!sync.isPaired)
    }
}

@MainActor
final class FakeNearbySession: NearbySession {
    private(set) var peers: [NearbyPeer]
    private(set) var discoveries = 0
    private(set) var stops = 0
    private(set) var disconnects = 0
    private var onPeerConfirmed: (@MainActor () -> Void)?

    init(peers: [NearbyPeer]) {
        self.peers = peers
    }

    func startDiscovery(onChange: @escaping @MainActor () -> Void) throws {
        discoveries += 1
    }

    func stopDiscovery() {
        stops += 1
    }

    func invite(_ peer: NearbyPeer, onPeerConfirmed: @escaping @MainActor () -> Void) throws {
        self.onPeerConfirmed = onPeerConfirmed
    }

    func confirm(_ peer: NearbyPeer) throws {}

    func disconnect() {
        disconnects += 1
        onPeerConfirmed = nil
    }

    func confirmFromPeer() {
        onPeerConfirmed?()
    }
}
