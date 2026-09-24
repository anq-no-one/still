import CryptoKit
import Foundation
import SwiftData

@Model
final class EncryptedProjectVocabulary {
    @Attribute(.unique) var projectID: UUID
    var sealedContent: Data

    init(projectID: UUID, sealedContent: Data) {
        self.projectID = projectID
        self.sealedContent = sealedContent
    }
}

@MainActor
protocol ProjectVocabularyRepository {
    func load() throws -> [ProjectVocabulary]
    func save(_ vocabulary: ProjectVocabulary) throws
}

@MainActor
struct EncryptedProjectVocabularyRepository: ProjectVocabularyRepository {
    private let context: ModelContext
    private let cipher: LibraryCipher

    init(context: ModelContext, key: SymmetricKey) {
        self.context = context
        cipher = LibraryCipher(key: key)
    }

    func load() throws -> [ProjectVocabulary] {
        try context.fetch(FetchDescriptor<EncryptedProjectVocabulary>()).map { record in
            try JSONDecoder().decode(ProjectVocabulary.self, from: try cipher.open(record.sealedContent))
        }
    }

    func save(_ vocabulary: ProjectVocabulary) throws {
        let sealed = try cipher.seal(try JSONEncoder().encode(vocabulary))
        let projectID = vocabulary.projectID
        var descriptor = FetchDescriptor<EncryptedProjectVocabulary>(predicate: #Predicate { $0.projectID == projectID })
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            existing.sealedContent = sealed
        } else {
            context.insert(EncryptedProjectVocabulary(projectID: vocabulary.projectID, sealedContent: sealed))
        }

        try context.save()
    }
}

@MainActor
final class MemoryProjectVocabularyRepository: ProjectVocabularyRepository {
    private var vocabularies: [UUID: ProjectVocabulary] = [:]

    func load() throws -> [ProjectVocabulary] {
        Array(vocabularies.values)
    }

    func save(_ vocabulary: ProjectVocabulary) throws {
        vocabularies[vocabulary.projectID] = vocabulary
    }
}
