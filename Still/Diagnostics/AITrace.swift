import Foundation

/// Keeps what every on-device model was asked and what it answered, tied to
/// the recording it worked on, so a TestFlight bundle shows why a note, title
/// or task came out the way it did.
enum AITrace {
    @TaskLocal static var recordingID: UUID?
    @TaskLocal static var stage: String?

    static func record(_ name: String, ms: Double? = nil, _ fields: [String: String]) {
        guard !DevLog.ai.isDisabled else { return }
        var fields = fields
        if let recordingID { fields["recordingID"] = recordingID.uuidString }
        if let stage, fields["stage"] == nil { fields["stage"] = stage }
        DevLog.ai.append(DevLog.record(.ai, name, ms: ms, fields: fields))
    }

    static func speakers(_ speakers: [Speaker]) -> String {
        speakers.map { speaker in
            "\(speaker.id.uuidString.prefix(8)) \"\(speaker.name)\" origin=\(speaker.origin?.rawValue ?? "-") you=\(speaker.isYou) source=\(speaker.nameSource?.rawValue ?? "-") suggested=\(speaker.suggestedName ?? "-") voiceprint=\(speaker.voiceprint != nil)"
        }
        .joined(separator: "\n")
    }

    static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "unencodable"
    }
}
