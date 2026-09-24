import SwiftUI
import UniformTypeIdentifiers

struct AudioImportView: View {
    let importer: AudioImporter

    @State private var isChoosingFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(importer.fileName ?? String(localized: "Audio File"), systemImage: "waveform")
                .font(.headline)
                .lineLimit(2)

            if case .failed(let message) = importer.phase {
                failure(message)
            } else {
                progress
            }
        }
        .padding(24)
        .stillSheetWidth(mac: 420)
        .interactiveDismissDisabled()
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result {
                importer.start(url)
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: fraction) {
                Text(status)
            }
            .accessibilityValue(fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "")

            Text("Still reads the file without changing it and transcribes it on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { importer.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Close", role: .cancel) { importer.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Choose Another File…") { isChoosingFile = true }
                Button("Try Again") { importer.retry() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var fraction: Double? {
        switch importer.phase {
        case .decoding(let fraction), .transcribing(let fraction): fraction
        case .idle, .reading, .imported, .failed: nil
        }
    }

    private var status: LocalizedStringKey {
        switch importer.phase {
        case .decoding: "Preparing the audio"
        case .transcribing: "Transcribing on this device"
        case .idle, .reading, .imported, .failed: "Reading the file"
        }
    }
}

#if os(macOS)
struct AudioImportCommand: View {
    let importer: AudioImporter
    let navigation: LibraryNavigation

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Import Audio…") {
            openWindow(id: StillApp.libraryWindowID)
            navigation.isChoosingAudioFile = true
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
        .disabled(!importer.canStart)
    }
}
#endif
