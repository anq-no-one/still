import Foundation

struct MCPClientInfo: Equatable, Sendable {
    let name: String
    let version: String?
}

/// One MCP conversation over a single connection. It speaks JSON-RPC 2.0 and
/// answers only while access is allowed, so turning access off refuses the
/// next request even on a connection that is already open.
@MainActor
final class MCPSession {
    static let protocolVersion = "2025-06-18"
    static let supportedProtocolVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let accessOffMessage = "AI tool access is off. Turn on \"Allow AI tools to read meetings\" in Still Settings."

    static func deniedMessage(for client: MCPClientInfo?) -> String {
        guard let client else { return accessOffMessage }
        return "Still has not approved \"\(client.name)\". In Still, open Settings > AI Tools, turn on access and approve it, then reconnect."
    }

    private let tools: MeetingTools
    private let isAllowed: (MCPClientInfo?) -> Bool
    private let onInitialize: (MCPClientInfo) -> Void
    private let serverVersion: String

    private(set) var client: MCPClientInfo?

    init(
        source: MeetingSource,
        serverVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        isAllowed: @escaping (MCPClientInfo?) -> Bool,
        onInitialize: @escaping (MCPClientInfo) -> Void = { _ in }
    ) {
        tools = MeetingTools(source: source)
        self.serverVersion = serverVersion
        self.isAllowed = isAllowed
        self.onInitialize = onInitialize
    }

    func handle(line: Data) -> Data? {
        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: line)
        } catch {
            let isJSON = (try? JSONDecoder().decode(JSONValue.self, from: line)) != nil
            return encode(.failure(.null, JSONRPCError(
                code: isJSON ? JSONRPCError.invalidRequest : JSONRPCError.parseError,
                message: isJSON ? "Invalid JSON-RPC request." : "Parse error."
            )))
        }

        guard request.jsonrpc == "2.0" else {
            return request.id.flatMap { encode(.failure($0, JSONRPCError(code: JSONRPCError.invalidRequest, message: "jsonrpc must be \"2.0\"."))) }
        }

        guard let id = request.id else {
            return nil
        }

        do {
            return encode(.success(id, try respond(to: request)))
        } catch {
            return encode(.failure(id, error))
        }
    }

    private func respond(to request: JSONRPCRequest) throws(JSONRPCError) -> JSONValue {
        if request.method == "ping" { return [:] }

        if request.method == "initialize" {
            client = Self.clientInfo(in: request.params)
            if let client { onInitialize(client) }
        }

        guard isAllowed(client) else {
            throw JSONRPCError(code: JSONRPCError.accessDenied, message: Self.deniedMessage(for: client))
        }

        switch request.method {
        case "initialize":
            return initialize(request.params)
        case "tools/list":
            return ["tools": .array(MeetingTools.definitions)]
        case "tools/call":
            guard let name = request.params?["name"]?.stringValue else {
                throw .invalidParams("tools/call needs a tool name.")
            }
            return try tools.call(name, arguments: request.params?["arguments"]?.objectValue ?? [:])
        case "resources/list":
            return try listResources()
        case "resources/read":
            return try readResource(request.params)
        case "resources/templates/list":
            return ["resourceTemplates": [MeetingResource.template]]
        case "prompts/list":
            return ["prompts": []]
        default:
            throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "Method not found: \(request.method)")
        }
    }

    private func initialize(_ params: JSONValue?) -> JSONValue {
        let requested = params?["protocolVersion"]?.stringValue
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersion
        return [
            "protocolVersion": .string(version),
            "capabilities": [
                "tools": ["listChanged": false],
                "resources": ["listChanged": false, "subscribe": false],
            ],
            "serverInfo": [
                "name": "still",
                "title": "Still",
                "version": .string(serverVersion),
            ],
            "instructions": "Still is the user's private meeting notebook on this Mac. Use list_meetings or search_meetings to find a meeting, then get_meeting for its notes and get_transcript for what each person said and when. Everything is read-only.",
        ]
    }

    private func listResources() throws(JSONRPCError) -> JSONValue {
        do {
            let meetings = try tools.source.meetings().sorted { $0.startedAt > $1.startedAt }
            return ["resources": .array(meetings.map(MeetingResource.descriptor))]
        } catch {
            throw Self.sourceError(error)
        }
    }

    private func readResource(_ params: JSONValue?) throws(JSONRPCError) -> JSONValue {
        guard let uri = params?["uri"]?.stringValue else {
            throw .invalidParams("resources/read needs a uri.")
        }
        do {
            guard let id = MeetingResource.meetingID(in: uri), let markdown = try tools.source.markdown(forMeeting: id) else {
                throw JSONRPCError(code: JSONRPCError.resourceNotFound, message: "Resource not found: \(uri)")
            }
            return ["contents": [["uri": .string(uri), "mimeType": "text/markdown", "text": .string(markdown)]]]
        } catch let error as JSONRPCError {
            throw error
        } catch {
            throw Self.sourceError(error)
        }
    }

    private static func sourceError(_ error: Error) -> JSONRPCError {
        if case MeetingSourceError.locked = error {
            return JSONRPCError(code: JSONRPCError.libraryLocked, message: MeetingTools.lockedMessage)
        }
        return JSONRPCError(code: -32603, message: "Still could not read the Library.")
    }

    private static func clientInfo(in params: JSONValue?) -> MCPClientInfo? {
        guard let info = params?["clientInfo"], let name = info["name"]?.stringValue, !name.isEmpty else { return nil }
        return MCPClientInfo(name: String(name.prefix(80)), version: info["version"]?.stringValue.map { String($0.prefix(40)) })
    }

    private func encode(_ response: JSONRPCResponse) -> Data? {
        try? JSONLine.encode(response)
    }
}

enum MeetingResource {
    static let scheme = "still://meetings/"

    static let template: JSONValue = [
        "uriTemplate": "still://meetings/{id}",
        "name": "meeting",
        "title": "Meeting",
        "description": "A meeting's notes and transcript as Markdown.",
        "mimeType": "text/markdown",
    ]

    static func uri(for id: UUID) -> String {
        scheme + id.uuidString
    }

    static func meetingID(in uri: String) -> UUID? {
        guard uri.hasPrefix(scheme) else { return nil }
        return UUID(uuidString: String(uri.dropFirst(scheme.count)))
    }

    @MainActor
    static func descriptor(_ meeting: MeetingRecord) -> JSONValue {
        [
            "uri": .string(uri(for: meeting.id)),
            "name": .string(meeting.title),
            "title": .string(meeting.title),
            "description": .string("Meeting on \(meeting.startedAt.formatted(.iso8601))"),
            "mimeType": "text/markdown",
        ]
    }
}
