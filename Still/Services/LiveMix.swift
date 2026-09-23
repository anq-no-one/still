struct LiveMix {
    enum Source: Hashable {
        case microphone
        case systemAudio
    }

    struct Stretch: Equatable {
        var samples: [Float]
        var isSealed: Bool
    }

    private let settle: Int
    private let realignAfter: Int
    private var samples: [Float] = []
    private var cursors: [Source: Int] = [:]

    init(settle: Int, realignAfter: Int) {
        self.settle = settle
        self.realignAfter = realignAfter
    }

    mutating func add(_ incoming: [Float], from source: Source) {
        var cursor = cursors[source] ?? samples.count
        if samples.count - cursor > realignAfter {
            cursor = samples.count
        }

        let end = cursor + incoming.count
        if samples.count < end {
            samples += Array(repeating: 0, count: end - samples.count)
        }
        for (offset, sample) in incoming.enumerated() {
            samples[cursor + offset] = min(1, max(-1, samples[cursor + offset] + sample))
        }
        cursors[source] = end
    }

    mutating func openStretch(sealingAfter limit: Int) -> Stretch {
        guard samples.count >= limit + settle else { return Stretch(samples: samples, isSealed: false) }

        let stretch = Array(samples.prefix(limit))
        samples.removeFirst(limit)
        cursors = cursors.mapValues { max(0, $0 - limit) }
        return Stretch(samples: stretch, isSealed: true)
    }
}
