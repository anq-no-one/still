import Foundation
import Synchronization
#if os(iOS)
import UIKit
#endif

/// Logs the moments the system asks the app to give memory back, with what
/// the app held at that instant: the last thing seen before a jetsam kill.
final class MemoryPressureMonitor: Sendable {
    private let source = Mutex<DispatchSourceMemoryPressure?>(nil)
    private let stream: DevLogStream

    init(stream: DevLogStream = DevLog.main) {
        self.stream = stream
    }

    func start() {
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        pressure.setEventHandler { [stream] in
            let event = pressure.data
            stream.append(DevLog.record(.event, "memory.pressure", thread: nil, fields: Self.snapshot(level: event.contains(.critical) ? "critical" : "warning")))
        }
        source.withLock { $0?.cancel(); $0 = pressure }
        pressure.resume()
        #if os(iOS)
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [stream] _ in
            stream.append(DevLog.record(.event, "memory.warning", thread: nil, fields: Self.snapshot(level: "memoryWarning")))
        }
        #endif
    }

    static func snapshot(level: String) -> [String: String] {
        var fields = ProcessProbe.memory().fields
        fields["level"] = level
        fields.merge(ResourceProbes.read()) { first, _ in first }
        let objects = LiveObjects.snapshot().filter { $0.value != 0 }
        if !objects.isEmpty {
            fields["liveObjects"] = objects.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        }
        return fields
    }
}
