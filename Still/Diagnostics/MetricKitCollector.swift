import Foundation
import MetricKit

/// The system's own measurements: launch time, hangs with call stacks,
/// crashes, CPU and memory, delivered about once a day and kept on device.
final class MetricKitCollector: NSObject, MXMetricManagerSubscriber, Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func start() {
        MXMetricManager.shared.add(self)
        store(MXMetricManager.shared.pastDiagnosticPayloads.map { ("diagnostic", $0.timeStampEnd, $0.jsonRepresentation()) })
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        store(payloads.map { ("metrics", $0.timeStampEnd, $0.jsonRepresentation()) })
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        store(payloads.map { ("diagnostic", $0.timeStampEnd, $0.jsonRepresentation()) })
    }

    private func store(_ payloads: [(kind: String, end: Date, json: Data)]) {
        guard !payloads.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for payload in payloads {
            let stamp = payload.end.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "-")
            let url = directory.appending(path: "\(payload.kind)-\(stamp).json")
            guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            try? payload.json.write(to: url, options: .atomic)
            DevLog.event("metrickit.\(payload.kind)", ["file": url.lastPathComponent, "bytes": String(payload.json.count)])
        }
    }
}
