import SwiftUI

struct MemorySectionsView: View {
    let recordingID: UUID
    let library: Library
    let extraction: MemoryExtraction
    let play: (TimeInterval) -> Void

    @State private var failure: String?

    var body: some View {
        if let recording, recording.isReadyForExtraction {
            VStack(alignment: .leading, spacing: 18) {
                if extraction.processingIDs.contains(recordingID) || recording.needsExtraction {
                    ProgressView("Finding decisions and tasks…")
                        .font(.callout)
                }

                MemorySection(title: "Decisions", items: visible(.decision), play: play, review: review, edit: nil)
                MemorySection(title: "Facts", items: visible(.fact), play: play, review: review, edit: nil)
                MemorySection(title: "Proposed Tasks", items: visible(.task), play: play, review: review, edit: edit)

                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                footer(for: recording)
            }
        }
    }

    private var recording: Recording? {
        library.recordings.first { $0.id == recordingID }
    }

    private func visible(_ kind: MemoryKind) -> [MemoryItem] {
        (recording?.memory?.items(of: kind) ?? []).filter { !$0.isDeclined }
    }

    @ViewBuilder
    private func footer(for recording: Recording) -> some View {
        HStack {
            if let withheld = recording.memory?.run?.withheldCount, withheld > 0 {
                Text("Still left out \(withheld) statements it could not trace to the transcript.")
            }
            Spacer()
            Button("Find Again", systemImage: "arrow.clockwise") {
                Task { await extraction.reprocess(recordingID) }
            }
            .disabled(extraction.processingIDs.contains(recordingID))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
    }

    private func review(_ item: MemoryItem, _ review: MemoryReview) {
        perform { try library.review(item.id, inRecording: recordingID, as: review) }
    }

    private func edit(_ item: MemoryItem, _ text: String) {
        perform { try library.edit(item.id, inRecording: recordingID, to: text) }
    }

    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct MemorySection: View {
    let title: LocalizedStringKey
    let items: [MemoryItem]
    let play: (TimeInterval) -> Void
    let review: (MemoryItem, MemoryReview) -> Void
    let edit: ((MemoryItem, String) -> Void)?

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)

                ForEach(items) { item in
                    MemoryRow(item: item, play: play, review: review, edit: edit)
                }
            }
        }
    }
}

enum MemoryRowMenu {
    enum Action: Hashable, Sendable {
        case approve
        case edit
        case showSource
        case decline
    }

    static func actions(for item: MemoryItem, canEdit: Bool) -> [Action] {
        var actions: [Action] = []
        if item.status == .extracted || item.status == .proposed {
            actions.append(.approve)
        }
        if canEdit {
            actions.append(.edit)
        }
        actions.append(.showSource)
        actions.append(.decline)
        return actions
    }
}

private struct MemoryRow: View {
    let item: MemoryItem
    let play: (TimeInterval) -> Void
    let review: (MemoryItem, MemoryReview) -> Void
    let edit: ((MemoryItem, String) -> Void)?

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(item.sourceStart.recordingDurationText) { play(item.sourceStart) }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .accessibilityHint("Plays the recording from \(item.sourceStart.recordingDurationText)")

                if isEditing {
                    TextField("Task", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                } else {
                    Text(item.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                statusMark
            }

            if isEditing {
                HStack {
                    Spacer()
                    Button("Cancel") { isEditing = false }
                    Button("Save", action: save)
                }
                .font(.caption)
                .buttonStyle(.borderless)
            } else if hasMetadata {
                HStack(spacing: 12) {
                    metadata
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            ForEach(menuActions, id: \.self) { action in
                menuButton(for: action)
            }
        }
    }

    @ViewBuilder
    private var statusMark: some View {
        if item.status == .confirmed || item.status == .accepted {
            Label(item.kind == .task ? "Accepted" : "Confirmed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var metadata: some View {
        if let owner = item.owner {
            Label(owner, systemImage: "person")
                .foregroundStyle(.secondary)
        }
        if let due = item.due {
            Label(due, systemImage: "calendar")
                .foregroundStyle(.secondary)
        }
        if item.isEdited {
            Image(systemName: "pencil")
                .foregroundStyle(.secondary)
                .accessibilityLabel("You edited this")
        }
    }

    private var hasMetadata: Bool {
        item.owner != nil || item.due != nil || item.isEdited
    }

    private var menuActions: [MemoryRowMenu.Action] {
        MemoryRowMenu.actions(for: item, canEdit: edit != nil)
    }

    @ViewBuilder
    private func menuButton(for action: MemoryRowMenu.Action) -> some View {
        switch action {
        case .approve:
            Button(item.kind == .task ? "Accept" : "Confirm", systemImage: "checkmark") {
                review(item, .approved)
            }
        case .edit:
            Button("Edit", systemImage: "pencil") {
                draft = item.text
                isEditing = true
            }
        case .showSource:
            Button("Show source", systemImage: "play") {
                play(item.sourceStart)
            }
        case .decline:
            Button(item.kind == .task ? "Dismiss" : "Reject", systemImage: "xmark", role: .destructive) {
                review(item, .declined)
            }
        }
    }

    private func save() {
        edit?(item, draft)
        isEditing = false
    }
}
