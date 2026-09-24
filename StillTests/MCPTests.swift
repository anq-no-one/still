import Foundation
import Testing
@testable import Still

struct JSONLineBufferTests {
    @Test
    func joinsChunksIntoWholeLines() {
        var buffer = JSONLineBuffer()

        #expect(buffer.append(Data(#"{"a":"#.utf8)).isEmpty)
        let lines = buffer.append(Data("1}\r\n\n  \n{\"b\":2}\n{\"c\"".utf8))

        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"b":2}"#])
        #expect(buffer.append(Data(":3}\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == [#"{"c":3}"#])
    }

    @Test
    func encodesOneMessagePerLine() throws {
        let data = try JSONLine.encode(JSONValue.object(["text": "two\nlines"]))
        let text = String(decoding: data, as: UTF8.self)

        #expect(text == "{\"text\":\"two\\nlines\"}\n")
        #expect(text.filter { $0 == "\n" }.count == 1)
    }

    @Test
    func keepsIntegerIDsIntegers() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":7,"x":1.5,"ok":true}"#.utf8))

        #expect(value["id"] == .int(7))
        #expect(value["x"] == .double(1.5))
        #expect(value["ok"] == .bool(true))
    }
}

@MainActor
struct MCPSessionTests {
    @Test
    func initializeNegotiatesTheProtocolAndReportsTheClient() throws {
        var clients: [MCPClientInfo] = []
        let session = MCPSession(source: FakeMeetingSource(), serverVersion: "1.0", isAllowed: { _ in true }) {
            clients.append($0)
        }

        let reply = try call(session, id: 1, "initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "claude-code", "version": "2.1.0"],
        ])

        #expect(reply["result"]?["protocolVersion"] == "2025-06-18")
        #expect(reply["result"]?["serverInfo"]?["name"] == "still")
        #expect(reply["result"]?["capabilities"]?["tools"] != nil)
        #expect(clients == [MCPClientInfo(name: "claude-code", version: "2.1.0")])
    }

    @Test
    func anUnknownProtocolVersionGetsTheLatestOne() throws {
        let session = MCPSession(source: FakeMeetingSource(), isAllowed: { _ in true })

        let reply = try call(session, id: 1, "initialize", ["protocolVersion": "1999-01-01"])

        #expect(reply["result"]?["protocolVersion"] == .string(MCPSession.protocolVersion))
    }

    @Test
    func notificationsGetNoReply() {
        let session = MCPSession(source: FakeMeetingSource(), isAllowed: { _ in true })

        #expect(session.handle(line: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
    }

    @Test
    func malformedInputGetsJSONRPCErrors() throws {
        let session = MCPSession(source: FakeMeetingSource(), isAllowed: { _ in true })

        let parse = try decode(session.handle(line: Data("{not json".utf8)))
        let unknown = try call(session, id: "a", "meetings/delete", nil)

        #expect(parse["error"]?["code"] == .int(JSONRPCError.parseError))
        #expect(parse["id"] == .null)
        #expect(unknown["error"]?["code"] == .int(JSONRPCError.methodNotFound))
        #expect(unknown["id"] == "a")
    }

    @Test
    func listsReadOnlyToolsWithObjectSchemas() throws {
        let session = MCPSession(source: FakeMeetingSource(), isAllowed: { _ in true })

        let tools = try #require(try call(session, id: 2, "tools/list", nil)["result"]?["tools"]?.arrayValue)

        #expect(tools.compactMap { $0["name"]?.stringValue } == [
            "list_meetings", "get_meeting", "get_transcript", "search_meetings", "list_action_items", "list_decisions",
        ])
        for tool in tools {
            #expect(tool["inputSchema"]?["type"] == "object")
            #expect(tool["annotations"]?["readOnlyHint"] == true)
            #expect(tool["description"]?.stringValue?.isEmpty == false)
        }
        let getMeeting = tools.first { $0["name"] == "get_meeting" }
        #expect(getMeeting?["inputSchema"]?["required"] == ["id"])
    }

    @Test
    func refusesEverythingWhileAccessIsOff() throws {
        let session = MCPSession(source: FakeMeetingSource(), isAllowed: { _ in false })

        let initialize = try call(session, id: 1, "initialize", ["protocolVersion": "2025-06-18"])
        let tools = try call(session, id: 2, "tools/call", ["name": "list_meetings"])

        #expect(initialize["error"]?["code"] == .int(JSONRPCError.accessDenied))
        #expect(tools["error"]?["code"] == .int(JSONRPCError.accessDenied))
        #expect(tools["result"] == nil)
    }

    @Test
    func aLockedLibraryIsAClearToolError() throws {
        let source = FakeMeetingSource(recordings: [Fixture.planning()])
        source.isLocked = true
        let session = MCPSession(source: source, isAllowed: { _ in true })

        let result = try call(session, id: 3, "tools/call", ["name": "list_meetings"])["result"]
        let resources = try call(session, id: 4, "resources/list", nil)

        #expect(result?["isError"] == true)
        #expect(result?["content"]?.arrayValue?.first?["text"] == .string(MeetingTools.lockedMessage))
        #expect(resources["error"]?["code"] == .int(JSONRPCError.libraryLocked))
    }

    @Test
    func anUnknownToolIsInvalidParams() throws {
        let session = MCPSession(source: FakeMeetingSource(), isAllowed: { _ in true })

        let reply = try call(session, id: 5, "tools/call", ["name": "delete_everything"])

        #expect(reply["error"]?["code"] == .int(JSONRPCError.invalidParams))
    }

    @Test
    func readsAMeetingAsAMarkdownResource() throws {
        let planning = Fixture.planning()
        let session = MCPSession(source: FakeMeetingSource(recordings: [planning]), isAllowed: { _ in true })

        let resources = try #require(try call(session, id: 6, "resources/list", nil)["result"]?["resources"]?.arrayValue)
        let uri = try #require(resources.first?["uri"])
        let contents = try call(session, id: 7, "resources/read", ["uri": uri])["result"]?["contents"]?.arrayValue?.first

        #expect(uri == .string("still://meetings/\(planning.id.uuidString)"))
        #expect(contents?["mimeType"] == "text/markdown")
        #expect(contents?["text"]?.stringValue?.hasPrefix("# Q4 planning") == true)
    }
}

@MainActor
struct MeetingToolTests {
    @Test
    func listsMeetingsNewestFirstAndPages() throws {
        let tools = MeetingTools(source: FakeMeetingSource(recordings: [Fixture.planning(), Fixture.retro()]))

        let first = try structured(tools.call("list_meetings", arguments: ["limit": 1]))
        let second = try structured(tools.call("list_meetings", arguments: ["limit": 1, "offset": 1]))

        #expect(first["total"] == 2)
        #expect(first["meetings"]?.arrayValue?.first?["title"] == "Sprint retro")
        #expect(first["next_offset"] == 1)
        #expect(second["meetings"]?.arrayValue?.first?["title"] == "Q4 planning")
        #expect(second["meetings"]?.arrayValue?.first?["participants"] == ["You", "Dana Kim"])
        #expect(second["meetings"]?.arrayValue?.first?["action_item_count"] == 1)
        #expect(second["next_offset"] == nil)
    }

    @Test
    func filtersMeetingsByDate() throws {
        let tools = MeetingTools(source: FakeMeetingSource(recordings: [Fixture.planning(), Fixture.retro()]))

        let result = try structured(tools.call("list_meetings", arguments: ["since": "2026-09-10"]))

        #expect(result["meetings"]?.arrayValue?.compactMap { $0["title"]?.stringValue } == ["Sprint retro"])
    }

    @Test
    func returnsAMeetingWithParticipantsAndNotes() throws {
        let planning = Fixture.planning()
        let tools = MeetingTools(source: FakeMeetingSource(recordings: [planning]))

        let meeting = try structured(tools.call("get_meeting", arguments: ["id": .string(planning.id.uuidString.lowercased())]))

        #expect(meeting["title"] == "Q4 planning")
        #expect(meeting["started_at"] == "2026-09-01T09:00:00Z")
        #expect(meeting["ended_at"] == "2026-09-01T09:30:00Z")
        #expect(meeting["participants"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["You", "Dana Kim"])
        #expect(meeting["notes"]?["decisions"]?.arrayValue?.first?["text"] == "Ship the beta on Friday.")
        #expect(meeting["notes"]?["action_items"]?.arrayValue?.first?["time_seconds"] == .double(12.5))
        #expect(meeting["notes"]?["user_notes"] == "Check budget")
        #expect(meeting["segment_count"] == 2)
    }

    @Test
    func returnsTheTranscriptWithSpeakersAndTimes() throws {
        let planning = Fixture.planning()
        let tools = MeetingTools(source: FakeMeetingSource(recordings: [planning]))

        let all = try structured(tools.call("get_transcript", arguments: ["id": .string(planning.id.uuidString)]))
        let late = try structured(tools.call("get_transcript", arguments: ["id": .string(planning.id.uuidString), "from_seconds": 10]))

        let segments = try #require(all["segments"]?.arrayValue)
        #expect(segments.map { $0["speaker"] } == ["You", "Dana Kim"])
        #expect(segments.map { $0["text"] } == ["Ship the beta on Friday.", "Dana will email the vendor."])
        #expect(segments.first?["start_seconds"] == .double(0))
        #expect(segments.last?["end_seconds"] == .double(15.25))
        #expect(late["segments"]?.arrayValue?.count == 1)
    }

    @Test
    func aTranscriptWithoutSegmentsComesBackAsText() throws {
        let plain = Recording(title: "Old", transcript: "Hello there", duration: 5)
        let tools = MeetingTools(source: FakeMeetingSource(recordings: [plain]))

        let result = try structured(tools.call("get_transcript", arguments: ["id": .string(plain.id.uuidString)]))

        #expect(result["text"] == "Hello there")
        #expect(result["segments"] == [])
    }

    @Test
    func searchFindsTheMeetingAndTheMoment() throws {
        let planning = Fixture.planning()
        let tools = MeetingTools(source: FakeMeetingSource(recordings: [planning, Fixture.retro()]))

        let result = try structured(tools.call("search_meetings", arguments: ["query": "vendor"]))
        let hits = try #require(result["results"]?.arrayValue)

        #expect(hits.contains { $0["meeting_title"] == "Q4 planning" && $0["match"] == "transcript" && $0["time_seconds"] == .double(12.5) })
        #expect(hits.allSatisfy { $0["meeting_id"] == .string(planning.id.uuidString) })
    }

    @Test
    func listsActionItemsAndDecisionsAcrossMeetings() throws {
        let tools = MeetingTools(source: FakeMeetingSource(recordings: [Fixture.planning(), Fixture.retro()]))

        let actions = try structured(tools.call("list_action_items", arguments: [:]))
        let decisions = try structured(tools.call("list_decisions", arguments: ["until": "2026-09-05T00:00:00Z"]))

        #expect(actions["action_items"]?.arrayValue?.compactMap { $0["text"]?.stringValue } == [
            "Book the retro room.", "Dana will email the vendor.",
        ])
        #expect(actions["action_items"]?.arrayValue?.last?["meeting_title"] == "Q4 planning")
        #expect(decisions["decisions"]?.arrayValue?.compactMap { $0["text"]?.stringValue } == ["Ship the beta on Friday."])
    }

    @Test
    func badArgumentsAreToolErrorsTheModelCanRead() throws {
        let tools = MeetingTools(source: FakeMeetingSource(recordings: [Fixture.planning()]))

        let missing = try tools.call("get_meeting", arguments: [:])
        let unknown = try tools.call("get_meeting", arguments: ["id": .string(UUID().uuidString)])
        let badDate = try tools.call("list_meetings", arguments: ["since": "last week"])
        let badLimit = try tools.call("list_meetings", arguments: ["limit": 0])

        for result in [missing, unknown, badDate, badLimit] {
            #expect(result["isError"] == true)
            #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue?.isEmpty == false)
        }
    }

    private func structured(_ result: JSONValue) throws -> JSONValue {
        #expect(result["isError"] == false)
        let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        let structured = try #require(result["structuredContent"])
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == structured)
        return structured
    }
}

@MainActor
struct MCPAccessTests {
    @Test
    func staysOffUntilTheUserTurnsItOn() {
        let access = MCPAccess(settings: MemoryMCPAccessSettings(), source: FakeMeetingSource(), socketURL: Fixture.socketURL())

        #expect(!access.isEnabled)
        #expect(!access.isAllowed(MCPClientInfo(name: "claude-code", version: nil)))
    }

    @Test
    func revokingAClientBlocksItUntilAllowedAgain() {
        let settings = MemoryMCPAccessSettings()
        let access = MCPAccess(settings: settings, source: FakeMeetingSource(), socketURL: Fixture.socketURL())
        access.enable()
        defer { access.disable() }
        let client = MCPConnectedClient(id: UUID(), name: "codex-mcp-client", version: "0.40", connectedAt: .now)

        access.revoke(client)

        #expect(!access.isAllowed(MCPClientInfo(name: "codex-mcp-client", version: nil)))
        #expect(access.isAllowed(MCPClientInfo(name: "claude-code", version: nil)))
        #expect(settings.blockedClients() == ["codex-mcp-client"])

        access.allow("codex-mcp-client")

        #expect(access.isAllowed(MCPClientInfo(name: "codex-mcp-client", version: nil)))
    }

    @Test
    func clientSnippetsPointAtTheBundledHelper() {
        let path = "/Applications/Still.app/Contents/Helpers/still-mcp"

        #expect(MCPClientConfig.claudeCode(helperPath: path) == "claude mcp add --scope user still -- \(path)")
        #expect(MCPClientConfig.codex(helperPath: path) == "[mcp_servers.still]\ncommand = \"\(path)\"")
        #expect(MCPClientConfig.shellQuoted("/Volumes/My Apps/Still.app") == "'/Volumes/My Apps/Still.app'")
    }
}

@MainActor
struct MCPHelperIntegrationTests {
    @Test
    func theBundledHelperRelaysAConversationToTheApp() async throws {
        let socketURL = Fixture.socketURL()
        let access = MCPAccess(
            settings: MemoryMCPAccessSettings(),
            source: FakeMeetingSource(recordings: [Fixture.planning()]),
            socketURL: socketURL
        )
        access.enable()
        defer { access.disable() }
        #expect(access.failure == nil)

        let output = try await runHelper(socketURL: socketURL, input: [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"integration","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_meetings","arguments":{"query":"beta"}}}"#,
        ])

        let replies = try output.split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        #expect(replies.map { $0["id"] } == [1, 2, 3])
        #expect(replies[0]["result"]?["serverInfo"]?["name"] == "still")
        #expect(replies[1]["result"]?["tools"]?.arrayValue?.count == MeetingTools.Tool.allCases.count)
        #expect(replies[2]["result"]?["structuredContent"]?["results"]?.arrayValue?.isEmpty == false)
    }

    @Test
    func theHelperExplainsWhenStillIsNotListening() async throws {
        let output = try await runHelper(socketURL: Fixture.socketURL(), input: [
            #"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#,
        ])

        let reply = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        #expect(reply["id"] == 9)
        #expect(reply["error"]?["code"] == .int(JSONRPCError.accessDenied))
    }

    private func runHelper(socketURL: URL, input: [String]) async throws -> String {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/still-mcp")
        try #require(FileManager.default.isExecutableFile(atPath: helper.path(percentEncoded: false)))

        let process = Process()
        process.executableURL = helper
        process.environment = [MCPSocketLocation.overrideKey: socketURL.path(percentEncoded: false)]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()

        let reading = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
        try stdin.fileHandleForWriting.write(contentsOf: Data((input.joined(separator: "\n") + "\n").utf8))
        try stdin.fileHandleForWriting.close()

        let data = await reading.value
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class FakeMeetingSource: MeetingSource {
    var recordings: [Recording]
    var isLocked = false

    init(recordings: [Recording] = []) {
        self.recordings = recordings
    }

    func meetings() throws -> [MeetingRecord] {
        guard !isLocked else { throw MeetingSourceError.locked }
        return recordings.map(MeetingRecord.init)
    }

    func search(_ query: String) throws -> [MeetingSearchHit] {
        guard !isLocked else { throw MeetingSourceError.locked }
        return LibrarySearch.results(for: query, in: recordings).map(MeetingSearchHit.init)
    }

    func markdown(forMeeting id: UUID) throws -> String? {
        guard !isLocked else { throw MeetingSourceError.locked }
        return recordings.first { $0.id == id }.map(RecordingDocument.markdown)
    }
}

final class MemoryMCPAccessSettings: MCPAccessSettingsStore, @unchecked Sendable {
    private var enabled = false
    private var blocked: [String] = []

    func isEnabled() -> Bool { enabled }
    func setEnabled(_ value: Bool) { enabled = value }
    func blockedClients() -> [String] { blocked }
    func setBlockedClients(_ names: [String]) { blocked = names }
}

private enum Fixture {
    static func socketURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "mcp-\(UUID().uuidString.prefix(8)).sock")
    }

    static func planning() -> Recording {
        let you = Speaker(name: "You", origin: .microphone, isYou: true)
        let dana = Speaker(name: "Dana Kim", origin: .system, isYou: false)
        let decision = TranscriptSegment(start: 0, end: 4, text: "Ship the beta on Friday.", language: "en", confidence: 0.9, speakerID: you.id)
        let action = TranscriptSegment(start: 12.5, end: 15.25, text: "Dana will email the vendor.", language: "en", confidence: 0.9, speakerID: dana.id)

        return Recording(
            title: "Q4 planning",
            transcript: [decision, action].plainText,
            segments: [decision, action],
            speakers: [you, dana],
            note: Note(
                template: .meeting,
                decisions: [NoteItem(text: decision.text, sourceSegmentIDs: [decision.id])],
                actions: [NoteItem(text: action.text, sourceSegmentIDs: [action.id])],
                userText: "Check budget"
            ),
            createdAt: Date(timeIntervalSince1970: 1_788_253_200),
            duration: 1800
        )
    }

    static func retro() -> Recording {
        let segment = TranscriptSegment(start: 3, end: 6, text: "Book the retro room.", language: "en", confidence: 0.8)

        return Recording(
            title: "Sprint retro",
            transcript: segment.text,
            segments: [segment],
            note: Note(template: .meeting, actions: [NoteItem(text: segment.text, sourceSegmentIDs: [segment.id])]),
            createdAt: Date(timeIntervalSince1970: 1_789_462_800),
            duration: 900
        )
    }
}

@MainActor
private func call(_ session: MCPSession, id: JSONValue, _ method: String, _ params: JSONValue?) throws -> JSONValue {
    var request: [String: JSONValue] = ["jsonrpc": "2.0", "id": id, "method": .string(method)]
    request["params"] = params
    return try decode(session.handle(line: try JSONEncoder().encode(JSONValue.object(request))))
}

private func decode(_ data: Data?) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: try #require(data))
}
