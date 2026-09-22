import Foundation
import Network

/// Bonjour discovery plus a direct TLS connection. The bytes it carries are the
/// same sealed Sync Changes and audio chunks iCloud carries, so a Recording
/// synced either way converges to the same thing.
@MainActor
final class NetworkNearbySession: NearbySession {
    static let serviceType = "_still-sync._tcp"
    static let confirmation = Data("still-pair-confirm".utf8)

    private var browser: NWBrowser?
    private var listener: NWListener?
    private var connection: NWConnection?
    private var onPeerConfirmed: (@MainActor () -> Void)?

    private(set) var peers: [NearbyPeer] = []

    func startDiscovery(onChange: @escaping @MainActor () -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { results, _ in
            Task { @MainActor in
                self.peers = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return NearbyPeer(id: UUID(uuidString: name) ?? UUID(), name: name)
                }
                onChange()
            }
        }
        browser.start(queue: .main)
        self.browser = browser

        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(type: Self.serviceType)
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                self.connection = connection
                connection.start(queue: .main)
                self.listenForConfirmation(on: connection)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stopDiscovery() {
        browser?.cancel()
        listener?.cancel()
        browser = nil
        listener = nil
        peers = []
    }

    func invite(_ peer: NearbyPeer, onPeerConfirmed: @escaping @MainActor () -> Void) throws {
        self.onPeerConfirmed = onPeerConfirmed

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(
            to: .service(name: peer.name, type: Self.serviceType, domain: "local", interface: nil),
            using: parameters
        )
        connection.start(queue: .main)
        self.connection = connection
        listenForConfirmation(on: connection)
    }

    /// Both sides send the same word when their own user says yes, and both
    /// sides listen for it. Without this the pairing state machine would wait
    /// for a confirmation that never arrived.
    private func listenForConfirmation(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.confirmation.count) { data, _, isComplete, error in
            if let data, data == Self.confirmation {
                Task { @MainActor in self.onPeerConfirmed?() }
                return
            }

            guard error == nil, !isComplete else { return }

            Task { @MainActor in
                guard self.connection === connection else { return }
                self.listenForConfirmation(on: connection)
            }
        }
    }

    func confirm(_ peer: NearbyPeer) throws {
        guard let connection else { throw SyncError.unreachable }

        connection.send(content: Self.confirmation, completion: .contentProcessed { _ in })
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        onPeerConfirmed = nil
    }
}
