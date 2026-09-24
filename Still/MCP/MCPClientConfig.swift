import Foundation

enum MCPClientConfig {
    static let serverName = "still"

    static func claudeCode(helperPath: String) -> String {
        "claude mcp add --scope user \(serverName) -- \(shellQuoted(helperPath))"
    }

    static func codex(helperPath: String) -> String {
        """
        [mcp_servers.\(serverName)]
        command = "\(helperPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
        """
    }

    static func shellQuoted(_ text: String) -> String {
        guard text.contains(where: { !$0.isLetter && !$0.isNumber && !"/._-".contains($0) }) else { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
