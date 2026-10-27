import Foundation

struct TeamsAccessibilityNode: Equatable, Sendable {
    var role: String = ""
    var identifier: String = ""
    var title: String = ""
    var description: String = ""
    var children: [TeamsAccessibilityNode] = []
}

enum TeamsActiveSpeakerLabels {
    static func names(in node: TeamsAccessibilityNode) -> [String] {
        Array(Set(collect(in: node, participant: false))).sorted()
    }

    static func speakingLabels(in node: TeamsAccessibilityNode) -> [String] {
        let own = [node.title, node.description].filter { $0.lowercased().contains("speak") }
        return own + node.children.flatMap(speakingLabels(in:))
    }

    private static func collect(in node: TeamsAccessibilityNode, participant: Bool) -> [String] {
        let identifier = node.identifier.lowercased()
        guard !["chat", "message", "transcript", "caption"].contains(where: identifier.contains),
              !["AXTextArea", "AXTextField"].contains(node.role)
        else { return [] }
        let participant = participant || ["participant", "video-tile", "speaker-tile"].contains(where: identifier.contains)
        var names = participant ? [node.title, node.description].compactMap(name(in:)) : []
        if participant, node.description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "speaking",
           let name = name(in: "\(node.title) is speaking") {
            names.append(name)
        }
        return names + node.children.flatMap { collect(in: $0, participant: participant) }
    }

    private static func name(in label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.lowercased().contains("not speaking") else { return nil }
        let patterns = [
            #"^(.+?)\s+is speaking[.!]?$"#,
            #"^(.+?)[,，]\s*speaking[.!]?$"#,
            #"^(.+?)\s*\(speaking\)$"#,
            #"^Speaking:\s*(.+?)$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  let range = Range(match.range(at: 1), in: trimmed)
            else { continue }
            let name = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 128,
                  !name.contains(where: { $0.isNewline }),
                  !["you", "me"].contains(name.lowercased())
            else { continue }
            return name
        }
        return nil
    }
}

struct TeamsActiveSpeakerSnapshot: Equatable, Sendable {
    enum Status: String, Sendable {
        case available
        case permissionRequired
        case teamsNotRunning
        case unavailable
    }

    var names: [String] = []
    var status: Status = .available
    var nodes = 0
    var speakingLabels: [String] = []
}

protocol TeamsActiveSpeakerReading: Sendable {
    func snapshot(processIdentifiers: [Int32]) async -> TeamsActiveSpeakerSnapshot
}

#if os(macOS)
import ApplicationServices

actor TeamsActiveSpeakerReader: TeamsActiveSpeakerReading {
    @MainActor
    static var hasAccess: Bool { AXIsProcessTrusted() }

    @MainActor
    static func requestAccess() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func snapshot(processIdentifiers: [Int32]) -> TeamsActiveSpeakerSnapshot {
        guard !processIdentifiers.isEmpty else { return TeamsActiveSpeakerSnapshot(status: .teamsNotRunning) }
        guard AXIsProcessTrusted() else { return TeamsActiveSpeakerSnapshot(status: .permissionRequired) }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        let budget = 1_500
        var remaining = budget
        var roots: [TeamsAccessibilityNode] = []
        for pid in processIdentifiers {
            let application = AXUIElementCreateApplication(pid)
            if enabledWebAccessibility.insert(pid).inserted {
                AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            if let node = read(application, depth: 0, remaining: &remaining, deadline: deadline) {
                roots.append(node)
            }
        }
        guard !roots.isEmpty else { return TeamsActiveSpeakerSnapshot(status: .unavailable) }
        return TeamsActiveSpeakerSnapshot(
            names: Array(Set(roots.flatMap(TeamsActiveSpeakerLabels.names(in:)))).sorted(),
            nodes: budget - remaining,
            speakingLabels: Array(Set(roots.flatMap(TeamsActiveSpeakerLabels.speakingLabels(in:)))).sorted()
        )
    }

    private var enabledWebAccessibility: Set<Int32> = []

    private func read(
        _ element: AXUIElement,
        depth: Int,
        remaining: inout Int,
        deadline: ContinuousClock.Instant
    ) -> TeamsAccessibilityNode? {
        guard remaining > 0, depth < 48, ContinuousClock.now < deadline else { return nil }
        remaining -= 1
        AXUIElementSetMessagingTimeout(element, 0.02)
        let attributes = [
            kAXRoleAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute,
            "AXDOMIdentifier", "AXDOMClassList",
        ] as CFArray
        var copied: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &copied) == .success,
              let values = copied as? [Any], values.count == 7
        else { return nil }
        let classes = (values[6] as? [String] ?? []).joined(separator: " ")
        var node = TeamsAccessibilityNode(
            role: values[0] as? String ?? "",
            identifier: [values[1] as? String, values[5] as? String, classes].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "),
            title: values[2] as? String ?? "",
            description: values[3] as? String ?? ""
        )
        if ["chat", "message", "transcript", "caption"].contains(where: node.identifier.lowercased().contains)
            || ["AXTextArea", "AXTextField"].contains(node.role) {
            return node
        }
        for child in (values[4] as? [AXUIElement] ?? []).prefix(200) {
            if let parsed = read(child, depth: depth + 1, remaining: &remaining, deadline: deadline) {
                node.children.append(parsed)
            }
        }
        return node
    }
}
#endif
