import Foundation

struct Recording: Identifiable, Encodable, Equatable, Sendable {
    let id: UUID
    var title: String
    var transcript: String
    var segments: [TranscriptSegment]
    var speakers: [Speaker]
    var expectedParticipants: [String]?
    var note: Note?
    let createdAt: Date
    let duration: TimeInterval
    var updatedAt: Date
    var deletedAt: Date?
    var archivedAt: Date?
    var projectID: UUID?
    var projectAssignedAt: Date?
    var mixedMediaSpans: [TimeSpan]?
    var memory: RecordingMemory?
    var importedFrom: ImportedFile?
    var isProcessing = false
    var titleSource: TitleSource?

    init(
        id: UUID = UUID(),
        title: String,
        transcript: String,
        segments: [TranscriptSegment] = [],
        speakers: [Speaker] = [],
        expectedParticipants: [String]? = nil,
        note: Note? = nil,
        createdAt: Date = .now,
        duration: TimeInterval,
        updatedAt: Date = .now,
        deletedAt: Date? = nil,
        archivedAt: Date? = nil,
        projectID: UUID? = nil,
        projectAssignedAt: Date? = nil,
        mixedMediaSpans: [TimeSpan]? = nil,
        memory: RecordingMemory? = nil,
        importedFrom: ImportedFile? = nil,
        isProcessing: Bool = false
    ) {
        self.id = id
        self.title = title
        self.transcript = transcript
        self.segments = segments
        self.speakers = speakers
        self.expectedParticipants = expectedParticipants
        self.note = note
        self.createdAt = createdAt
        self.duration = duration
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.archivedAt = archivedAt
        self.projectID = projectID
        self.projectAssignedAt = projectAssignedAt
        self.mixedMediaSpans = mixedMediaSpans
        self.memory = memory
        self.importedFrom = importedFrom
        self.isProcessing = isProcessing
    }

    var isTitleChosenByUser: Bool {
        switch titleSource {
        case .user: true
        case .automatic: false
        case nil: !Self.looksGenerated(title, transcript: transcript, createdAt: createdAt)
        }
    }

    private static func looksGenerated(_ title: String, transcript: String, createdAt: Date) -> Bool {
        if title == RecordingTitle.dateTitle(createdAt) || title == RecordingTitle.from(transcript: transcript, date: createdAt) {
            return true
        }
        let titleWords = TitleText.normalizedWords(title)
        let openingWords = TitleText.normalizedWords(DisfluencyFilter.cleaned(transcript, language: nil))
        let compared = min(3, titleWords.count)
        return compared > 0 && Array(titleWords.prefix(compared)) == Array(openingWords.prefix(compared))
    }

    var isDeleted: Bool {
        deletedAt != nil
    }

    var isArchived: Bool {
        archivedAt != nil
    }

    var unclaimedParticipants: [String] {
        var taken = Set(speakers.map { VoiceProfiles.key(for: $0.name) })
        return (expectedParticipants ?? []).filter { taken.insert(VoiceProfiles.key(for: $0)).inserted }
    }

    func renamingSpeaker(_ speaker: Speaker, to name: String) -> Recording {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = speakers.firstIndex(where: { $0.id == speaker.id }) else { return self }

        var renamed = self
        renamed.speakers[index] = speakers[index].named(trimmed, by: .user)
        return renamed
    }

    func mergingSpeaker(_ duplicate: Speaker, into survivor: Speaker) -> Recording {
        guard duplicate.id != survivor.id,
              let duplicateIndex = speakers.firstIndex(where: { $0.id == duplicate.id }),
              let survivorIndex = speakers.firstIndex(where: { $0.id == survivor.id })
        else { return self }

        var merged = self
        merged.segments = segments.map { segment in
            segment.speakerID == duplicate.id ? segment.attributed(to: survivor) : segment
        }
        if merged.speakers[survivorIndex].suggestedName == nil,
           let suggestion = merged.speakers[duplicateIndex].suggestedName {
            merged.speakers[survivorIndex] = merged.speakers[survivorIndex].suggesting(suggestion)
        }
        merged.speakers = merged.speakers.filter { $0.id != duplicate.id }
        return merged
    }

    func confirmingSuggestedName(of speaker: Speaker) -> Recording {
        updatingSpeaker(speaker) { $0.confirmingSuggestedName() }
    }

    func rejectingSuggestedName(of speaker: Speaker) -> Recording {
        updatingSpeaker(speaker) { $0.rejectingSuggestedName() }
    }

    private func updatingSpeaker(_ speaker: Speaker, _ change: (Speaker) -> Speaker) -> Recording {
        guard let index = speakers.firstIndex(where: { $0.id == speaker.id }) else { return self }

        var updated = self
        updated.speakers[index] = change(speakers[index])
        return updated
    }
}

extension Recording: Decodable {
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case transcript
        case segments
        case speakers
        case expectedParticipants
        case note
        case createdAt
        case duration
        case updatedAt
        case deletedAt
        case archivedAt
        case projectID
        case projectAssignedAt
        case mixedMediaSpans
        case memory
        case importedFrom
        case isProcessing
        case titleSource
    }

    /// Payloads sealed before processing existed carry no flag. They describe
    /// finished recordings, so the absence counts as done rather than stuck.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            transcript: try container.decode(String.self, forKey: .transcript),
            segments: try container.decode([TranscriptSegment].self, forKey: .segments),
            speakers: try container.decode([Speaker].self, forKey: .speakers),
            expectedParticipants: try container.decodeIfPresent([String].self, forKey: .expectedParticipants),
            note: try container.decodeIfPresent(Note.self, forKey: .note),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            duration: try container.decode(TimeInterval.self, forKey: .duration),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            deletedAt: try container.decodeIfPresent(Date.self, forKey: .deletedAt),
            archivedAt: try container.decodeIfPresent(Date.self, forKey: .archivedAt),
            projectID: try container.decodeIfPresent(UUID.self, forKey: .projectID),
            projectAssignedAt: try container.decodeIfPresent(Date.self, forKey: .projectAssignedAt),
            mixedMediaSpans: try container.decodeIfPresent([TimeSpan].self, forKey: .mixedMediaSpans),
            memory: try container.decodeIfPresent(RecordingMemory.self, forKey: .memory),
            importedFrom: try container.decodeIfPresent(ImportedFile.self, forKey: .importedFrom),
            isProcessing: try container.decodeIfPresent(Bool.self, forKey: .isProcessing) ?? false
        )
        titleSource = try container.decodeIfPresent(TitleSource.self, forKey: .titleSource)
    }
}
