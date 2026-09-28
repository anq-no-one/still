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

    var hasPendingSave: Bool {
        pendingSave != nil
    }

    /// Takes in a newer copy from the Library, for example when the background
    /// transcript lands while the detail is open. Refuses while an edit is
    /// still waiting out its coalescing delay, so a keystroke never loses.
    func refresh(to updated: Recording) {
        guard pendingSave == nil, updated.id == recording.id else { return }
        recording = updated
        saveFailure = nil
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

    func apply(_ changes: [VocabularyChange]) {
        for change in changes {
            guard let index = recording.segments.firstIndex(where: { $0.id == change.segmentID }),
                  !recording.segments[index].isCorrected,
                  recording.segments[index].text == change.before
            else { continue }
            recording.segments[index].correction = change.after
        }
        recording.transcript = recording.segments.plainText
        scheduleSave()
    }

    func updateNoteText(_ text: String) {
        var note = note
        note.userText = text
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

    func renameSpeaker(_ speaker: Speaker, to name: String) {
        recording = recording.renamingSpeaker(speaker, to: name)
        do {
            try library.rememberOwner(speaker, as: name)
        } catch {
            saveFailure = error.localizedDescription
        }
        scheduleSave()
    }

    func mergeSpeaker(_ duplicate: Speaker, into survivor: Speaker) {
        recording = recording.mergingSpeaker(duplicate, into: survivor)
        scheduleSave()
    }

    func confirmSuggestedName(of speaker: Speaker) {
        recording = recording.confirmingSuggestedName(of: speaker)
        scheduleSave()
    }

    func rejectSuggestedName(of speaker: Speaker) {
        recording = recording.rejectingSuggestedName(of: speaker)
        scheduleSave()
    }

    func confirmProject() {
        recording.assign(toProject: recording.projectID)
        scheduleSave()
    }

    func assign(toProject projectID: UUID?) {
        recording.assign(toProject: projectID)
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
            self?.pendingSave = nil
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
