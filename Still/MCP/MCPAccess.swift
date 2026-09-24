#if os(macOS)
import Foundation
import Observation

protocol MCPAccessSettingsStore: Sendable {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool)
    func blockedClients() -> [String]
    func setBlockedClients(_ names: [String])
}

struct UserDefaultsMCPAccessSettings: MCPAccessSettingsStore {
    private static let enabledKey = "mcp.enabled"
    private static let blockedKey = "mcp.blockedClients"

    func isEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
    }

    func blockedClients() -> [String] {
        UserDefaults.standard.stringArray(forKey: Self.blockedKey) ?? []
    }

    func setBlockedClients(_ names: [String]) {
        UserDefaults.standard.set(names, forKey: Self.blockedKey)
    }
}

struct MCPConnectedClient: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let version: String?
    let connectedAt: Date
}

/// Lets AI tools such as Claude Code and Codex read the Library through the
/// bundled `still-mcp` helper. Off until the user turns it on; turning it off
/// closes the socket and every open connection.
@MainActor
@Observable
final class MCPAccess {
    private let settings: MCPAccessSettingsStore
    private let source: MeetingSource
    private let server: MCPSocketServer
    private var connections: [UUID: MCPConnection] = [:]

    private(set) var isEnabled: Bool
    private(set) var clients: [MCPConnectedClient] = []
    private(set) var blockedClients: [String]
    private(set) var failure: String?

    init(settings: MCPAccessSettingsStore, source: MeetingSource, socketURL: URL = MCPSocketLocation.defaultURL) {
        self.settings = settings
        self.source = source
        server = MCPSocketServer(url: socketURL)
        isEnabled = settings.isEnabled()
        blockedClients = settings.blockedClients()
    }

    var helperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/still-mcp")
    }

    func startIfEnabled() {
        guard isEnabled else { return }
        startListening()
    }

    func enable() {
        isEnabled = true
        settings.setEnabled(true)
        startListening()
    }

    func disable() {
        isEnabled = false
        settings.setEnabled(false)
        server.stop()
        connections.values.forEach { $0.close() }
        connections.removeAll()
        clients.removeAll()
        failure = nil
    }

    func revoke(_ client: MCPConnectedClient) {
        if !blockedClients.contains(client.name) {
            blockedClients.append(client.name)
            settings.setBlockedClients(blockedClients)
        }
        for other in clients where other.name == client.name {
            connections[other.id]?.close()
        }
        clients.removeAll { $0.name == client.name }
    }

    func allow(_ name: String) {
        blockedClients.removeAll { $0 == name }
        settings.setBlockedClients(blockedClients)
    }

    func isAllowed(_ client: MCPClientInfo?) -> Bool {
        guard isEnabled else { return false }
        guard let client else { return true }
        return !blockedClients.contains(client.name)
    }

    private func startListening() {
        do {
            try server.start { [weak self] connection in
                Task { @MainActor in self?.serve(connection) }
            }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func serve(_ connection: MCPConnection) {
        guard isEnabled else {
            connection.close()
            return
        }
        connections[connection.id] = connection

        let session = MCPSession(
            source: source,
            isAllowed: { [weak self] client in self?.isAllowed(client) ?? false },
            onInitialize: { [weak self] client in self?.register(client, on: connection.id) }
        )

        Task { @MainActor [weak self] in
            for await line in connection.lines {
                if let reply = session.handle(line: line) {
                    connection.send(reply)
                }
            }
            connection.close()
            self?.connections[connection.id] = nil
            self?.clients.removeAll { $0.id == connection.id }
        }
    }

    private func register(_ client: MCPClientInfo, on connectionID: UUID) {
        guard isAllowed(client) else { return }
        clients.removeAll { $0.id == connectionID }
        clients.append(MCPConnectedClient(id: connectionID, name: client.name, version: client.version, connectedAt: .now))
    }
}
#endif
