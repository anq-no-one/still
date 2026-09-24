import CryptoKit
import Foundation
import SwiftData

@MainActor
protocol RecordingRepository {
    func load() throws -> [Recording]
    func save(_ recording: Recording) throws
    func delete(_ id: UUID) throws
}

@MainActor
struct EncryptedRecordingRepository: RecordingRepository {
    private let context: ModelContext
    private let cipher: LibraryCipher

    init(context: ModelContext, key: SymmetricKey) {
        self.context = context
        cipher = LibraryCipher(key: key)
    }

    func load() throws -> [Recording] {
        let descriptor = FetchDescriptor<EncryptedRecording>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        return try context.fetch(descriptor).map { record in
            let content = try JSONDecoder().decode(
                RecordingContent.self,
                from: try cipher.open(record.sealedContent)
            )
            return Recording(
                id: record.id,
                title: content.title,
                transcript: content.transcript,
                segments: content.segments,
                speakers: content.speakers,
                expectedParticipants: content.expectedParticipants,
                note: content.note,
                createdAt: record.createdAt,
                duration: record.duration,
                projectID: content.projectID,
                projectAssignedAt: content.projectAssignedAt
            )
        }
    }

    func save(_ recording: Recording) throws {
        let sealed = try cipher.seal(
            try JSONEncoder().encode(
                RecordingContent(
                    title: recording.title,
                    transcript: recording.transcript,
                    segments: recording.segments,
                    speakers: recording.speakers,
                    expectedParticipants: recording.expectedParticipants,
                    note: recording.note,
                    projectID: recording.projectID,
                    projectAssignedAt: recording.projectAssignedAt
                )
            )
        )

        if let existing = try record(for: recording.id) {
            existing.sealedContent = sealed
        } else {
            context.insert(
                EncryptedRecording(
                    id: recording.id,
                    createdAt: recording.createdAt,
                    duration: recording.duration,
                    sealedContent: sealed
                )
            )
        }

        try context.save()
    }

    func delete(_ id: UUID) throws {
        guard let existing = try record(for: id) else { return }

        context.delete(existing)
        try context.save()
    }

    private func record(for id: UUID) throws -> EncryptedRecording? {
        var descriptor = FetchDescriptor<EncryptedRecording>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
