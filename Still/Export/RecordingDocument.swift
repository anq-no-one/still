import Foundation

enum RecordingDocument {
    static func markdown(for recording: Recording) -> String {
        var lines = ["# \(recording.title)", ""]
        lines.append(recording.createdAt.formatted(date: .long, time: .shortened))
        lines.append("Duration \(recording.duration.recordingDurationText)")
        lines.append("")

        if let note = recording.note {
            lines.append("## \(note.template.title) notes")
            lines.append("")
            lines += section("Summary", note.summary, in: recording)
            lines += section("Decisions", note.decisions, in: recording)
            lines += section("Action items", note.actions, in: recording)

            if !note.userText.isEmpty {
                lines.append("### Your notes")
                lines.append("")
                lines.append(note.userText)
                lines.append("")
            }
        }

        lines.append("## Transcript")
        lines.append("")
        if recording.segments.isEmpty {
            lines.append(recording.transcript)
        } else {
            let names = Dictionary(recording.speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            let speakers = Dictionary(recording.segments.map { ($0.id, $0.speakerID) }, uniquingKeysWith: { first, _ in first })
            for sentence in ExtractiveNoteGenerator.sentences(in: recording.segments) {
                let name = sentence.sourceIDs.first.flatMap { speakers[$0] ?? nil }.flatMap { names[$0] }
                lines.append("- `\(sentence.start.recordingDurationText)` " + (name.map { "**\($0):** " } ?? "") + sentence.text)
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func plainText(for recording: Recording) -> String {
        markdown(for: recording)
            .replacingOccurrences(of: "### ", with: "")
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "# ", with: "")
            .replacingOccurrences(of: "- `", with: "")
            .replacingOccurrences(of: "` ", with: "  ")
    }

    private static func section(_ title: String, _ items: [NoteItem], in recording: Recording) -> [String] {
        guard !items.isEmpty else { return [] }

        var lines = ["### \(title)", ""]
        for item in items {
            let stamp = time(of: item, in: recording).map { "`\($0.recordingDurationText)` " } ?? ""
            let names = item.speakerNames(segments: recording.segments, speakers: recording.speakers)
            lines.append("- \(stamp)\(item.text)" + (names.isEmpty ? "" : " — \(names.formatted(.list(type: .and)))"))
        }
        lines.append("")
        return lines
    }

    private static func time(of item: NoteItem, in recording: Recording) -> TimeInterval? {
        guard let id = item.sourceSegmentIDs.first else { return nil }
        return recording.segments.first { $0.id == id }?.start
    }
}
