import AVFoundation
import FluidAudio
import Foundation

struct Item: Decodable {
    let audio: String
    let reference: String
}

struct LanguageResult {
    let language: String
    let medianWordErrorRate: Double
    let audioSeconds: Double
    let processingSeconds: Double
}

func samples(of path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        return []
    }
    try file.read(into: buffer)
    guard let channel = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    print("usage: still-eval <eval-set-dir> <parakeet-model-dir> <report.md>")
    exit(64)
}

let setDirectory = URL(fileURLWithPath: arguments[1])
let manifest = try JSONDecoder().decode(
    [String: [Item]].self,
    from: Data(contentsOf: setDirectory.appendingPathComponent("manifest.json"))
)
let manager = AsrManager()
try await manager.loadModels(try AsrModels.loadLocal(from: URL(fileURLWithPath: arguments[2])))

var results: [LanguageResult] = []
for language in manifest.keys.sorted() {
    var rates: [Double] = []
    var audioSeconds = 0.0
    var processingSeconds = 0.0
    for item in manifest[language] ?? [] {
        let audio = try samples(of: item.audio)
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let started = Date()
        let result = try await manager.transcribe(audio, decoderState: &state)
        processingSeconds += Date().timeIntervalSince(started)
        audioSeconds += Double(audio.count) / 16_000
        rates.append(WordErrorRate.value(reference: item.reference, hypothesis: result.text))
    }
    results.append(
        LanguageResult(
            language: language,
            medianWordErrorRate: median(rates),
            audioSeconds: audioSeconds,
            processingSeconds: processingSeconds
        )
    )
}

var report = """
# Word error rate on this Mac

Machine: \(ProcessInfo.processInfo.hostName.isEmpty ? "unknown" : "Mac") · \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)

| Language | Clips | Median WER | Gate | Real-time factor |
|---|---|---|---|---|

"""
for result in results {
    let clips = manifest[result.language]?.count ?? 0
    let gate = ReleaseGate.passes(wordErrorRate: result.medianWordErrorRate, language: result.language) ? "pass" : "fail"
    let factor = result.audioSeconds > 0 ? result.processingSeconds / result.audioSeconds : 0
    report += String(
        format: "| %@ | %d | %.1f%% | %@ | %.3f |\n",
        result.language, clips, result.medianWordErrorRate * 100, gate, factor
    )
}
try report.write(toFile: arguments[3], atomically: true, encoding: .utf8)
print(report)
