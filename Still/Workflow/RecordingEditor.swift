import Foundation
import Observation

/// Holds the recording the user is editing and writes changes back without
/// making them wait. Every edit lands in memory first, and a short coalescing
/// delay keeps a burst of keystrokes from becoming a burst of saves.
@MainActor
@Observable
final class RecordingEditor {
    static let saveDelay = Duration.milliseconds(600)

    private let library: Library
    private var pendingSave: Task<Void, Never>?

    private(set) var recording: Recording
    private(set) var saveFailure: String?

    init(recording: Recording, library: Library) {
        self.recording = recording
        self.library = library
    }

    var note: Note {
        recording.note ?? Note(template: .personalNote)
    }

    func rename(to title: String) {
        recording.title = title
        scheduleSave()
    }

    func correct(_ segment: TranscriptSegment, to text: String) {
        guard let index = recording.segments.firstIndex(where: { $0.id == segment.id }) else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        recording.segments[index].correction = trimmed == segment.text || trimmed.isEmpty ? nil : trimmed
        recording.transcript = recording.segments.plainText
        scheduleSave()
    }

    func updateNoteText(_ text: String) {
        var note = note
        note.userText = text
        recording.note = note
        scheduleSave()
    }

    /// A different shape never costs the user their own words.
    func changeTemplate(to template: NoteTemplate) {
        var note = note
        note.template = template
        note.isTemplateUserChosen = true
        recording.note = note
        scheduleSave()
    }

    func addAction(_ text: String, citing segment: TranscriptSegment?) {
        var note = note
        note.actions.append(
            NoteItem(
                text: text,
                sourceSegmentIDs: segment.map { [$0.id] } ?? [],
                isUserAuthored: true
            )
        )
        recording.note = note
        scheduleSave()
    }

    /// Renaming touches the speaker group only. Segments point at it by id, so
    /// no transcript text changes.
    func renameSpeaker(_ speaker: Speaker, to name: String) {
        guard let index = recording.speakers.firstIndex(where: { $0.id == speaker.id }) else { return }

        recording.speakers[index].name = name
        scheduleSave()
    }

    func speaker(of segment: TranscriptSegment) -> Speaker? {
        guard let id = segment.speakerID else { return nil }
        return recording.speakers.first { $0.id == id }
    }

    func applyTranslations(_ segments: [TranscriptSegment]) {
        recording.segments = segments
        scheduleSave()
    }

    func segment(withID id: UUID) -> TranscriptSegment? {
        recording.segments.first { $0.id == id }
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        write()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }

    private func write() {
        do {
            try library.save(recording)
            saveFailure = nil
        } catch {
            saveFailure = error.localizedDescription
        }
    }
}
