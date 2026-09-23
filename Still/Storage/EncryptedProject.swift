import CryptoKit
import Foundation
import SwiftData

@Model
final class EncryptedProject {
    @Attribute(.unique) var id: UUID
    var sealedContent: Data

    init(id: UUID, sealedContent: Data) {
        self.id = id
        self.sealedContent = sealedContent
    }
}

@MainActor
protocol ProjectRepository {
    func load() throws -> [Project]
    func save(_ project: Project) throws
}

@MainActor
struct EncryptedProjectRepository: ProjectRepository {
    private let context: ModelContext
    private let cipher: LibraryCipher

    init(context: ModelContext, key: SymmetricKey) {
        self.context = context
        cipher = LibraryCipher(key: key)
    }

    func load() throws -> [Project] {
        try context.fetch(FetchDescriptor<EncryptedProject>()).map { record in
            try JSONDecoder().decode(Project.self, from: try cipher.open(record.sealedContent))
        }
    }

    func save(_ project: Project) throws {
        let sealed = try cipher.seal(try JSONEncoder().encode(project))
        let id = project.id
        var descriptor = FetchDescriptor<EncryptedProject>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            existing.sealedContent = sealed
        } else {
            context.insert(EncryptedProject(id: project.id, sealedContent: sealed))
        }

        try context.save()
    }
}

@MainActor
final class MemoryProjectRepository: ProjectRepository {
    private var projects: [UUID: Project] = [:]

    func load() throws -> [Project] {
        Array(projects.values)
    }

    func save(_ project: Project) throws {
        projects[project.id] = project
    }
}
