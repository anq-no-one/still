import Foundation

struct ProblemMarker: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        case tester
        case longHang
    }

    var id = UUID()
    var at = Date.now
    var reason: Reason
    var note: String
    var screen: String
}

/// "Something is wrong right now." A marker writes the moment into the log
/// and keeps what every thread, the memory and each subsystem looked like
/// then, because by the time a bundle is made the problem has often passed.
struct ProblemMarkers: Sendable {
    static let keeps = 20

    let directory: URL
    var stream: DevLogStream = DevLog.main

    @discardableResult
    func capture(_ marker: ProblemMarker, state: [String: [String: String]]? = nil) -> URL? {
        stream.append(DevLog.record(.event, "user.marker", thread: nil, fields: [
            "markerID": marker.id.uuidString,
            "reason": marker.reason.rawValue,
            "note": marker.note,
            "screen": marker.screen,
        ].merging(DiagnosticRecording.fields) { first, _ in first }))

        let stamp = marker.at.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let folder = directory.appending(path: "\(stamp)-\(marker.reason.rawValue)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = DevLogStream.plainEncoder
            encoder.outputFormatting.insert(.prettyPrinted)
            try encoder.encode(marker).write(to: folder.appending(path: "marker.json"))
            try StackSampler.allThreadsReport().write(to: folder.appending(path: "threads.txt"), atomically: true, encoding: .utf8)
            try encoder.encode(MemoryPressureMonitor.snapshot(level: "marker")).write(to: folder.appending(path: "memory.json"))
            if let state {
                try encoder.encode(state).write(to: folder.appending(path: "state.json"))
            }
        } catch {
            DevLog.error("user.markerSnapshotFailed", error)
            return nil
        }
        prune()
        return folder
    }

    func all() -> [ProblemMarker] {
        folders().compactMap { folder in
            (try? Data(contentsOf: folder.appending(path: "marker.json"))).flatMap {
                try? Self.decoder.decode(ProblemMarker.self, from: $0)
            }
        }
    }

    func folders() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter(\.hasDirectoryPath)
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func prune() {
        for folder in folders().dropFirst(Self.keeps) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return try Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))
        }
        return decoder
    }
}
