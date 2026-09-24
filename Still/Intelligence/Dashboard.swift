import Foundation

struct Dashboard: Equatable, Sendable {
    static let changeWindow: TimeInterval = 14 * 24 * 60 * 60

    let awaitingProject: [Recording]
    let proposedTasks: [SourcedItem]
    let changedDecisions: [DecisionThread]

    init(
        recordings: [Recording],
        now: Date = .now,
        changeWindow: TimeInterval = Self.changeWindow,
        validator: ProvenanceValidator = ProvenanceValidator()
    ) {
        let kept = recordings.filter { !$0.isDeleted }
        let sorted = kept.sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
        let assigned = sorted.filter(\.isProjectConfirmed)

        awaitingProject = sorted.filter { !$0.isProjectConfirmed }

        proposedTasks = assigned.flatMap { recording in
            (recording.memory?.items(of: .task) ?? [])
                .filter { $0.status == .proposed && validator.stillSupports($0, in: recording.segments) }
                .map { SourcedItem($0, in: recording) }
        }

        let since = now.addingTimeInterval(-changeWindow)
        let projectIDs = Set(assigned.compactMap(\.projectID))
        changedDecisions = projectIDs
            .flatMap { ProjectHistory(recordings: assigned, project: $0, validator: validator).threads }
            .filter { $0.hasChanged && $0.current.recordingDate >= since }
            .sorted { ProjectHistory.isEarlier($1.current, $0.current) }
    }

    var isEmpty: Bool {
        awaitingProject.isEmpty && proposedTasks.isEmpty && changedDecisions.isEmpty
    }
}
