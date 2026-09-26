import Foundation

enum AIAssistPrompt {
    static func prompt(note: Note, title: String, recordedAt: Date) -> String {
        var lines = [
            String(localized: "Help me work through my meeting notes from \"\(title)\" (\(recordedAt.formatted(date: .long, time: .shortened)))."),
            "",
        ]
        if !note.actions.isEmpty {
            lines.append(String(localized: "These are the action items I need to achieve. Help me plan how to get each of them done:"))
            lines += note.actions.map { "- \($0.text)" }
            lines.append("")
        }
        if !note.summary.isEmpty {
            lines.append(String(localized: "Summary:"))
            lines += note.summary.map { "- \($0.text)" }
            lines.append("")
        }
        if !note.decisions.isEmpty {
            lines.append(String(localized: "Decisions:"))
            lines += note.decisions.map { "- \($0.text)" }
            lines.append("")
        }
        if !note.userText.isEmpty {
            lines.append(String(localized: "My own notes:"))
            lines.append(note.userText)
            lines.append("")
        }
        lines.append(String(localized: "For anything else you need, fetch it yourself from Still, my meeting notebook on my Mac. In Still, open Settings, then AI Tools, turn on Allow AI tools to read meetings, and approve yourself there. Keep Still open with its library unlocked. Still exposes a local MCP server named \"still\" that Claude Code and Codex understand. Through it you can read transcripts, notes, facts, decisions, and tasks from my projects. It never shares audio and it cannot change anything."))
        return lines.joined(separator: "\n") + "\n"
    }
}
