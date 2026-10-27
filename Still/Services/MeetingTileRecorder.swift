#if os(macOS)
import Foundation

@MainActor
final class MeetingTileRecorder {
    struct Configuration: Sendable {
        var activeSpeakerCadence: TimeInterval = 0.5
        var isVoiceActive: @Sendable () -> Bool = { true }
        var now: @Sendable () -> Date = Date.init
    }

    private let root: URL
    private let activeSpeakers: any TeamsActiveSpeakerReading
    private let configuration: Configuration

    private var recordingID: UUID?
    private var startedAt: Date?
    private var speakerTimer: Task<Void, Never>?
    private var observations: [TileObservation] = []
    private var lastSpeakerStatus: TeamsActiveSpeakerSnapshot.Status?
    private var maximumNodes = 0
    private var speakingLabels: Set<String> = []

    init(
        root: URL,
        cipher _: LibraryCipher,
        activeSpeakers: any TeamsActiveSpeakerReading = TeamsActiveSpeakerReader(),
        configuration: Configuration = Configuration()
    ) {
        self.root = root
        self.activeSpeakers = activeSpeakers
        self.configuration = configuration
    }

    var isRunning: Bool {
        recordingID != nil
    }

    func start(recordingID: UUID) async {
        if isRunning { cancel() }
        guard !TeamsMeetingWindow.processIdentifiers().isEmpty else { return }
        self.recordingID = recordingID
        startedAt = configuration.now()
        observations = []
        lastSpeakerStatus = nil
        maximumNodes = 0
        speakingLabels = []
        speakerTimer = Task { [weak self] in
            await self?.observeSpeakers()
        }
    }

    func stop() async -> [SpeakerCue] {
        let id = recordingID
        let elapsed = startedAt.map { configuration.now().timeIntervalSince($0) } ?? 0
        let cues = TileCueBuilder.cues(from: observations, endingAt: elapsed)
        DevLog.event("teams.activeSpeakers.finished", [
            "observations": String(observations.count),
            "speakingObservations": String(observations.filter { !$0.activeSpeakerNames.isEmpty }.count),
            "cues": String(cues.count),
            "status": lastSpeakerStatus?.rawValue ?? "unavailable",
            "nodes": String(maximumNodes),
        ])
        AITrace.record("teams.activeSpeakers.labels", [
            "stage": "speakers",
            "labels": speakingLabels.sorted().prefix(40).joined(separator: " | "),
        ])
        reset()
        if let id { MeetingTileStore.discard(recordingID: id, root: root) }
        return cues
    }

    func cancel() {
        let id = recordingID
        reset()
        if let id { MeetingTileStore.discard(recordingID: id, root: root) }
    }

    private func reset() {
        speakerTimer?.cancel()
        speakerTimer = nil
        observations = []
        recordingID = nil
        startedAt = nil
    }

    private func observeSpeakers() async {
        while !Task.isCancelled {
            guard let recordingID, let startedAt else { return }
            let snapshot = await activeSpeakers.snapshot(processIdentifiers: TeamsMeetingWindow.processIdentifiers())
            guard !Task.isCancelled, self.recordingID == recordingID else { return }
            if snapshot.status != lastSpeakerStatus {
                DevLog.event("teams.activeSpeakers.status", ["status": snapshot.status.rawValue])
                lastSpeakerStatus = snapshot.status
            }
            maximumNodes = max(maximumNodes, snapshot.nodes)
            if speakingLabels.count < 200 { speakingLabels.formUnion(snapshot.speakingLabels) }
            observations.append(TileObservation(
                offset: configuration.now().timeIntervalSince(startedAt),
                names: [],
                activeSpeakerNames: configuration.isVoiceActive() && snapshot.status == .available ? snapshot.names : []
            ))
            try? await Task.sleep(for: .seconds(configuration.activeSpeakerCadence))
        }
    }
}
#endif
