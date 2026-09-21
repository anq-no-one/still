import SwiftUI

struct ExportMenu: View {
    let recording: Recording
    let library: Library

    var body: some View {
        Menu("Export", systemImage: "square.and.arrow.up") {
            ShareLink("Note as PDF", item: RecordingExport.pdf(recording), preview: preview("PDF"))
            ShareLink("Note as Markdown", item: RecordingExport.markdown(recording), preview: preview("Markdown"))
            ShareLink("Note as plain text", item: RecordingExport.plainText(recording), preview: preview("Text"))

            Divider()

            ShareLink(
                "All audio",
                item: RecordingExport.audio(recording, track: nil, load: mixedAudio),
                preview: preview("Audio")
            )

            ForEach(library.tracks(forRecording: recording.id), id: \.self) { track in
                ShareLink(
                    trackTitle(track),
                    item: RecordingExport.audio(recording, track: track, load: trackAudio(track)),
                    preview: preview("Audio")
                )
            }

            Divider()

            ShareLink(
                "Encrypted Still archive",
                item: RecordingExport.archive(recording, build: archive),
                preview: preview("Archive")
            )
        }
    }

    private func preview(_ label: String) -> SharePreview<Never, Never> {
        SharePreview("\(recording.title) — \(label)")
    }

    private func trackTitle(_ track: AudioTrack) -> String {
        switch track {
        case .microphone: "Microphone audio only"
        case .system: "System audio only"
        }
    }

    private var mixedAudio: @Sendable () throws -> Data {
        let library = library
        let recording = recording
        return { try MainActor.assumeIsolated { try library.audio(for: recording) } }
    }

    private func trackAudio(_ track: AudioTrack) -> @Sendable () throws -> Data {
        let library = library
        let recording = recording
        return { try MainActor.assumeIsolated { try library.audio(for: recording, track: track) } }
    }

    private var archive: @Sendable () throws -> Data {
        let library = library
        let recording = recording
        return {
            try MainActor.assumeIsolated {
                try library.archive(recording, tracks: library.tracks(forRecording: recording.id))
            }
        }
    }
}
