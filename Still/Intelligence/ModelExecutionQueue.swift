import Foundation

actor ModelExecutionQueue {
    private struct Waiting {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let prepare: @Sendable () -> Void
    private let cleanup: @Sendable () -> Void

    init(prepare: @escaping @Sendable () -> Void = {}, cleanup: @escaping @Sendable () -> Void = {}) {
        self.prepare = prepare
        self.cleanup = cleanup
    }

    private var busy = false
    private var waiting: [Waiting] = []

    var waitingRequestCount: Int { waiting.count }

    func perform<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if busy {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiting.append(Waiting(id: id, continuation: continuation))
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        } else {
            busy = true
        }
        defer { release() }
        try Task.checkCancellation()
        prepare()
        defer { cleanup() }
        return try await operation()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }
}
