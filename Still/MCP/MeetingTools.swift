import Foundation

@MainActor
struct MeetingTools {
    let source: MeetingSource

    static let lockedMessage = "Still's Library is locked. Open Still on this Mac and unlock it, then try again."

    func call(_ name: String, arguments: [String: JSONValue]) throws(JSONRPCError) -> JSONValue {
        guard let tool = Tool(rawValue: name) else {
            throw .invalidParams("Unknown tool: \(name)")
        }

        do {
            return Self.success(try run(tool, ToolArguments(arguments)))
        } catch MeetingSourceError.locked {
            return Self.failure(Self.lockedMessage)
        } catch let error as ToolArgumentError {
            return Self.failure(error.message)
        } catch {
            return Self.failure("Still could not read the Library.")
        }
    }

    private func run(_ tool: Tool, _ arguments: ToolArguments) throws -> JSONValue {
        switch tool {
        case .listMeetings: try listMeetings(arguments)
        case .getMeeting: try getMeeting(arguments)
        case .getTranscript: try getTranscript(arguments)
        case .searchMeetings: try searchMeetings(arguments)
        case .listActionItems: try listNoteItems(arguments, key: "action_items", items: \.actionItems)
        case .listDecisions: try listNoteItems(arguments, key: "decisions", items: \.decisions)
        case .listFacts: try listMemory(arguments, key: "facts", kinds: [.fact, .decision])
        case .listTasks: try listMemory(arguments, key: "tasks", kinds: [.task])
        }
    }

    private func listMeetings(_ arguments: ToolArguments) throws -> JSONValue {
        let meetings = try meetings(in: arguments)
        let offset = try arguments.int("offset", default: 0, range: 0...Int.max)
        let limit = try arguments.int("limit", default: 20, range: 1...100)
        let page = meetings.dropFirst(offset).prefix(limit)

        var result: [String: JSONValue] = [
            "total": .int(meetings.count),
            "offset": .int(offset),
            "meetings": .array(page.map(Self.summary)),
        ]
        if offset + page.count < meetings.count {
            result["next_offset"] = .int(offset + page.count)
        }
        return .object(result)
    }

    private func getMeeting(_ arguments: ToolArguments) throws -> JSONValue {
        let meeting = try meeting(arguments)

        return [
            "id": .string(meeting.id.uuidString),
            "title": .string(meeting.title),
            "started_at": Self.date(meeting.startedAt),
            "ended_at": Self.date(meeting.startedAt.addingTimeInterval(meeting.durationSeconds)),
            "updated_at": Self.date(meeting.updatedAt),
            "duration_seconds": Self.seconds(meeting.durationSeconds),
            "participants": .array(meeting.participants.map { participant in
                [
                    "id": .string(participant.id.uuidString),
                    "name": .string(participant.name),
                    "is_you": .bool(participant.isYou),
                ]
            }),
            "notes": meeting.notes.map(Self.notes) ?? .null,
            "segment_count": .int(meeting.segments.count),
        ]
    }

    private func getTranscript(_ arguments: ToolArguments) throws -> JSONValue {
        let meeting = try meeting(arguments)
        let from = try arguments.double("from_seconds")
        let to = try arguments.double("to_seconds")
        let offset = try arguments.int("offset", default: 0, range: 0...Int.max)
        let limit = try arguments.int("limit", default: 500, range: 1...2000)

        var result: [String: JSONValue] = [
            "meeting_id": .string(meeting.id.uuidString),
            "title": .string(meeting.title),
            "started_at": Self.date(meeting.startedAt),
        ]

        guard !meeting.segments.isEmpty else {
            result["segments"] = []
            result["text"] = .string(meeting.transcript)
            return .object(result)
        }

        let inRange = meeting.segments.filter { segment in
            (from.map { segment.endSeconds >= $0 } ?? true) && (to.map { segment.startSeconds <= $0 } ?? true)
        }
        let page = inRange.dropFirst(offset).prefix(limit)
        result["total"] = .int(inRange.count)
        result["segments"] = .array(page.map(Self.segment))
        if offset + page.count < inRange.count {
            result["next_offset"] = .int(offset + page.count)
        }
        return .object(result)
    }

    private func searchMeetings(_ arguments: ToolArguments) throws -> JSONValue {
        let query = try arguments.requiredString("query")
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count > 1 else {
            throw ToolArgumentError(message: "query needs at least two characters.")
        }
        let limit = try arguments.int("limit", default: 20, range: 1...100)
        let meetings = Dictionary(try source.meetings().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let results = try source.search(query).prefix(limit).map { hit -> JSONValue in
            let meeting = meetings[hit.meetingID]
            return [
                "meeting_id": .string(hit.meetingID.uuidString),
                "meeting_title": meeting.map { .string($0.title) } ?? .null,
                "started_at": meeting.map { Self.date($0.startedAt) } ?? .null,
                "match": .string(hit.match),
                "snippet": .string(hit.snippet),
                "time_seconds": hit.timeSeconds.map(Self.seconds) ?? .null,
                "segment_id": hit.segmentID.map { .string($0.uuidString) } ?? .null,
            ]
        }

        return ["query": .string(query), "results": .array(results)]
    }

    private func listMemory(_ arguments: ToolArguments, key: String, kinds: Set<MemoryKind>) throws -> JSONValue {
        let limit = try arguments.int("limit", default: 50, range: 1...500)
        let entries = try meetings(in: arguments).flatMap { meeting in
            meeting.memory.filter { kinds.contains($0.kind) }.map { item -> JSONValue in
                var entry: [String: JSONValue] = [
                    "id": .string(item.id),
                    "kind": .string(item.kind.rawValue),
                    "text": .string(item.text),
                    "verification": .string(item.verification),
                    "time_seconds": .double(item.timeSeconds),
                    "source_segment_ids": .array(item.sourceSegmentIDs.map { .string($0.uuidString) }),
                    "meeting_id": .string(meeting.id.uuidString),
                    "meeting_title": .string(meeting.title),
                    "started_at": Self.date(meeting.startedAt),
                ]
                if let owner = item.owner { entry["owner"] = .string(owner) }
                if let due = item.due { entry["due"] = .string(due) }
                return .object(entry)
            }
        }

        return [key: .array(Array(entries.prefix(limit))), "total": .int(entries.count)]
    }

    private func listNoteItems(
        _ arguments: ToolArguments,
        key: String,
        items: KeyPath<MeetingNotes, [MeetingNoteItem]>
    ) throws -> JSONValue {
        let limit = try arguments.int("limit", default: 50, range: 1...500)
        let entries = try meetings(in: arguments).flatMap { meeting in
            (meeting.notes?[keyPath: items] ?? []).map { item -> JSONValue in
                var entry = Self.noteItem(item).objectValue ?? [:]
                entry["meeting_id"] = .string(meeting.id.uuidString)
                entry["meeting_title"] = .string(meeting.title)
                entry["started_at"] = Self.date(meeting.startedAt)
                return .object(entry)
            }
        }

        return [key: .array(Array(entries.prefix(limit))), "total": .int(entries.count)]
    }

    private func meetings(in arguments: ToolArguments) throws -> [MeetingRecord] {
        let since = try arguments.date("since")
        let until = try arguments.date("until")

        return try source.meetings()
            .filter { meeting in
                (since.map { meeting.startedAt >= $0 } ?? true) && (until.map { meeting.startedAt <= $0 } ?? true)
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func meeting(_ arguments: ToolArguments) throws -> MeetingRecord {
        let id = try arguments.uuid("id")
        guard let meeting = try source.meetings().first(where: { $0.id == id }) else {
            throw ToolArgumentError(message: "No meeting has the id \(id.uuidString).")
        }
        return meeting
    }
}

extension MeetingTools {
    enum Tool: String, CaseIterable {
        case listMeetings = "list_meetings"
        case getMeeting = "get_meeting"
        case getTranscript = "get_transcript"
        case searchMeetings = "search_meetings"
        case listActionItems = "list_action_items"
        case listDecisions = "list_decisions"
        case listFacts = "list_facts"
        case listTasks = "list_tasks"

        var title: String {
            switch self {
            case .listMeetings: "List meetings"
            case .getMeeting: "Get meeting"
            case .getTranscript: "Get transcript"
            case .searchMeetings: "Search meetings"
            case .listActionItems: "List action items"
            case .listDecisions: "List decisions"
            case .listFacts: "List facts and decisions"
            case .listTasks: "List accepted tasks"
            }
        }

        var description: String {
            switch self {
            case .listMeetings:
                "Lists meetings recorded in Still, newest first, with title, start time, duration and participants. Use the id with get_meeting or get_transcript."
            case .getMeeting:
                "Returns one meeting's details and notes: participants, summary, decisions, action items and the user's own notes. Each note item points at the transcript segments it came from."
            case .getTranscript:
                "Returns a meeting's transcript as timestamped segments with the speaker of each one. Narrow it with from_seconds and to_seconds, and page with offset and limit."
            case .searchMeetings:
                "Searches meeting titles, transcripts and notes for words or a phrase, ignoring case and accents. Each result names the meeting and the time in the recording."
            case .listActionItems:
                "Lists action items from meeting notes across meetings, newest meeting first, each with its meeting and the time it was said."
            case .listDecisions:
                "Lists decisions from meeting notes across meetings, newest meeting first, each with its meeting and the time it was said."
            case .listFacts:
                "Lists facts and decisions Still found in meetings, each with the meeting, the time in the recording, its source segments, and whether the user confirmed it or it was automatically extracted. Rejected items are left out."
            case .listTasks:
                "Lists tasks the user accepted after review, each with the meeting, the time it was said and its source segments. Unreviewed task proposals are never included."
            }
        }

        var inputSchema: JSONValue {
            switch self {
            case .listMeetings:
                Self.schema([
                    "since": Self.dateProperty("Only meetings that started at or after this ISO 8601 date or time."),
                    "until": Self.dateProperty("Only meetings that started at or before this ISO 8601 date or time."),
                    "limit": Self.integerProperty("Most meetings to return.", minimum: 1, maximum: 100, default: 20),
                    "offset": Self.integerProperty("Meetings to skip, for paging.", minimum: 0, default: 0),
                ])
            case .getMeeting:
                Self.schema(["id": Self.idProperty], required: ["id"])
            case .getTranscript:
                Self.schema(
                    [
                        "id": Self.idProperty,
                        "from_seconds": ["type": "number", "minimum": 0, "description": "Start of the time range, in seconds from the start of the recording."],
                        "to_seconds": ["type": "number", "minimum": 0, "description": "End of the time range, in seconds from the start of the recording."],
                        "limit": Self.integerProperty("Most segments to return.", minimum: 1, maximum: 2000, default: 500),
                        "offset": Self.integerProperty("Segments to skip, for paging.", minimum: 0, default: 0),
                    ],
                    required: ["id"]
                )
            case .searchMeetings:
                Self.schema(
                    [
                        "query": ["type": "string", "minLength": 2, "description": "Words or a phrase to find."],
                        "limit": Self.integerProperty("Most results to return.", minimum: 1, maximum: 100, default: 20),
                    ],
                    required: ["query"]
                )
            case .listActionItems, .listDecisions, .listFacts, .listTasks:
                Self.schema([
                    "since": Self.dateProperty("Only meetings that started at or after this ISO 8601 date or time."),
                    "until": Self.dateProperty("Only meetings that started at or before this ISO 8601 date or time."),
                    "limit": Self.integerProperty("Most items to return.", minimum: 1, maximum: 500, default: 50),
                ])
            }
        }

        var definition: JSONValue {
            [
                "name": .string(rawValue),
                "title": .string(title),
                "description": .string(description),
                "inputSchema": inputSchema,
                "annotations": [
                    "title": .string(title),
                    "readOnlyHint": true,
                    "destructiveHint": false,
                    "idempotentHint": true,
                    "openWorldHint": false,
                ],
            ]
        }

        private static let idProperty: JSONValue = [
            "type": "string",
            "format": "uuid",
            "description": "The meeting id from list_meetings or search_meetings.",
        ]

        private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
            [
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
                "additionalProperties": false,
            ]
        }

        private static func dateProperty(_ description: String) -> JSONValue {
            ["type": "string", "description": .string(description)]
        }

        private static func integerProperty(_ description: String, minimum: Int, maximum: Int? = nil, default value: Int) -> JSONValue {
            var property: [String: JSONValue] = [
                "type": "integer",
                "minimum": .int(minimum),
                "default": .int(value),
                "description": .string(description),
            ]
            if let maximum { property["maximum"] = .int(maximum) }
            return .object(property)
        }
    }

    static var definitions: [JSONValue] {
        Tool.allCases.map(\.definition)
    }
}

extension MeetingTools {
    static func success(_ payload: JSONValue) -> JSONValue {
        [
            "content": [["type": "text", "text": .string(text(payload))]],
            "structuredContent": payload,
            "isError": false,
        ]
    }

    static func failure(_ message: String) -> JSONValue {
        [
            "content": [["type": "text", "text": .string(message)]],
            "isError": true,
        ]
    }

    private static func text(_ payload: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(payload), as: UTF8.self)) ?? ""
    }

    static func date(_ date: Date) -> JSONValue {
        .string(date.formatted(.iso8601))
    }

    static func seconds(_ seconds: TimeInterval) -> JSONValue {
        .double((seconds * 100).rounded() / 100)
    }

    private static func summary(_ meeting: MeetingRecord) -> JSONValue {
        [
            "id": .string(meeting.id.uuidString),
            "title": .string(meeting.title),
            "started_at": date(meeting.startedAt),
            "duration_seconds": seconds(meeting.durationSeconds),
            "participants": .array(meeting.participants.map { .string($0.name) }),
            "has_notes": .bool(meeting.notes != nil),
            "decision_count": .int(meeting.notes?.decisions.count ?? 0),
            "action_item_count": .int(meeting.notes?.actionItems.count ?? 0),
        ]
    }

    private static func notes(_ notes: MeetingNotes) -> JSONValue {
        [
            "kind": .string(notes.kind),
            "summary": .array(notes.summary.map(noteItem)),
            "decisions": .array(notes.decisions.map(noteItem)),
            "action_items": .array(notes.actionItems.map(noteItem)),
            "user_notes": .string(notes.userNotes),
        ]
    }

    fileprivate static func noteItem(_ item: MeetingNoteItem) -> JSONValue {
        [
            "id": .string(item.id.uuidString),
            "text": .string(item.text),
            "time_seconds": item.timeSeconds.map(seconds) ?? .null,
            "source_segment_ids": .array(item.sourceSegmentIDs.map { .string($0.uuidString) }),
            "user_authored": .bool(item.isUserAuthored),
        ]
    }

    private static func segment(_ segment: MeetingSegment) -> JSONValue {
        [
            "id": .string(segment.id.uuidString),
            "start_seconds": seconds(segment.startSeconds),
            "end_seconds": seconds(segment.endSeconds),
            "speaker": segment.speaker.map { .string($0) } ?? .null,
            "speaker_id": segment.speakerID.map { .string($0.uuidString) } ?? .null,
            "text": .string(segment.text),
            "language": segment.language.map { .string($0) } ?? .null,
        ]
    }
}

struct ToolArgumentError: Error {
    let message: String
}

struct ToolArguments {
    private let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) {
        self.values = values
    }

    func int(_ key: String, default value: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = values[key], raw != .null else { return value }
        guard let number = raw.intValue, range.contains(number) else {
            throw ToolArgumentError(message: "\(key) must be a whole number from \(range.lowerBound)\(range.upperBound == .max ? " up" : " to \(range.upperBound)").")
        }
        return number
    }

    func double(_ key: String) throws -> Double? {
        guard let raw = values[key], raw != .null else { return nil }
        guard let number = raw.doubleValue, number >= 0 else {
            throw ToolArgumentError(message: "\(key) must be a number of seconds, zero or more.")
        }
        return number
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = values[key]?.stringValue else {
            throw ToolArgumentError(message: "\(key) is required.")
        }
        return value
    }

    func uuid(_ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try requiredString(key).trimmingCharacters(in: .whitespaces)) else {
            throw ToolArgumentError(message: "\(key) must be a meeting id from list_meetings.")
        }
        return id
    }

    func date(_ key: String) throws -> Date? {
        guard let raw = values[key], raw != .null else { return nil }
        guard let text = raw.stringValue, let date = Self.parseDate(text) else {
            throw ToolArgumentError(message: "\(key) must be an ISO 8601 date such as 2026-09-01 or 2026-09-01T09:00:00Z.")
        }
        return date
    }

    private static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(trimmed, strategy: .iso8601) { return date }
        if let date = try? Date(trimmed, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(trimmed, strategy: Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }
}
