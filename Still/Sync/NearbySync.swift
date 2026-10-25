import Foundation
import Observation

struct NearbyPeer: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
}

/// Discovery and connection, kept behind a seam so pairing rules can be proved
/// without a second device on the network.
@MainActor
protocol NearbySession: AnyObject {
    var peers: [NearbyPeer] { get }

    func startDiscovery(onChange: @escaping @MainActor () -> Void) throws
    func stopDiscovery()
    func invite(_ peer: NearbyPeer, onPeerConfirmed: @escaping @MainActor () -> Void) throws
    func confirm(_ peer: NearbyPeer) throws
    func disconnect()
}

/// Direct sync between two devices the user owns. Pairing needs a yes on both
/// of them, and nothing transfers until both have said it. Turning it off stops
/// discovery and leaves the local Library and iCloud exactly as they were.
@MainActor
@Observable
final class NearbySync {
    enum State: Equatable {
        case off
        case discovering
        case awaitingConfirmation(NearbyPeer)
        case paired(NearbyPeer)
        case failed(String)
    }

    private let session: NearbySession
    private var localConfirmed = false
    private var peerConfirmed = false

    private(set) var state: State = .off {
        didSet { DevLog.event("sync.nearby.state", ["state": String(describing: state)]) }
    }

    init(session: NearbySession) {
        self.session = session
    }

    var peers: [NearbyPeer] {
        state == .off ? [] : session.peers
    }

    var isPaired: Bool {
        if case .paired = state { return true }
        return false
    }

    func enable() {
        guard state == .off else { return }

        do {
            try session.startDiscovery { [weak self] in self?.refresh() }
            state = .discovering
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops discovery and transfer. Local recordings and iCloud sync are
    /// untouched, because this transport only ever carried copies.
    func disable() {
        session.stopDiscovery()
        session.disconnect()
        localConfirmed = false
        peerConfirmed = false
        state = .off
    }

    func invite(_ peer: NearbyPeer) {
        guard state == .discovering else { return }

        do {
            localConfirmed = false
            peerConfirmed = false
            try session.invite(peer) { [weak self] in self?.receivePeerConfirmation(peer) }
            state = .awaitingConfirmation(peer)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func confirm() {
        guard case .awaitingConfirmation(let peer) = state else { return }

        do {
            try session.confirm(peer)
            localConfirmed = true
            settleIfBothConfirmed(peer)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func receivePeerConfirmation(_ peer: NearbyPeer) {
        peerConfirmed = true
        settleIfBothConfirmed(peer)
    }

    private func settleIfBothConfirmed(_ peer: NearbyPeer) {
        guard localConfirmed, peerConfirmed else { return }
        state = .paired(peer)
    }

    private func refresh() {
        guard state == .discovering else { return }
        state = .discovering
    }
}
