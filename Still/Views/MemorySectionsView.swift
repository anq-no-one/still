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
            }

            HStack(spacing: 12) {
                statusLabel
                Spacer()
                actions
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch item.status {
        case .extracted, .proposed:
            Label("Automatically extracted", systemImage: "sparkles")
                .foregroundStyle(.secondary)
        case .confirmed, .accepted:
            Label(item.kind == .task ? "Accepted" : "Confirmed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .rejected, .dismissed:
            EmptyView()
        }
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

    @ViewBuilder
    private var actions: some View {
        if isEditing {
            Button("Cancel") { isEditing = false }
            Button("Save", action: save)
        } else if item.kind == .task {
            if item.status == .proposed {
                Button("Accept") { review(item, .approved) }
            }
            if edit != nil {
                Button("Edit") {
                    draft = item.text
                    isEditing = true
                }
            }
            Button("Dismiss", role: .destructive) { review(item, .declined) }
        } else {
            if item.status == .extracted {
                Button("Confirm") { review(item, .approved) }
            }
            Button("Reject", role: .destructive) { review(item, .declined) }
        }
    }

    private func save() {
        edit?(item, draft)
        isEditing = false
    }
}
