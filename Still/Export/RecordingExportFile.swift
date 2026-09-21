import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The bytes are produced inside the transfer, so choosing Export builds
/// nothing until the user completes the share.
struct RecordingExportFile: Transferable, Sendable {
    let filename: String
    let build: @Sendable () throws -> Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            let url = URL.temporaryDirectory.appending(path: file.filename)
            try file.build().write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

enum RecordingExport {
    static func markdown(_ recording: Recording) -> RecordingExportFile {
        RecordingExportFile(filename: "\(safeName(recording)).md") {
            Data(RecordingDocument.markdown(for: recording).utf8)
        }
    }

    static func plainText(_ recording: Recording) -> RecordingExportFile {
        RecordingExportFile(filename: "\(safeName(recording)).txt") {
            Data(RecordingDocument.plainText(for: recording).utf8)
        }
    }

    static func pdf(_ recording: Recording) -> RecordingExportFile {
        RecordingExportFile(filename: "\(safeName(recording)).pdf") {
            PDFDocumentBuilder.pdf(from: RecordingDocument.plainText(for: recording))
        }
    }

    static func audio(
        _ recording: Recording,
        track: AudioTrack?,
        load: @escaping @Sendable () throws -> Data
    ) -> RecordingExportFile {
        let suffix = track.map { "-\($0.rawValue)" } ?? ""
        return RecordingExportFile(filename: "\(safeName(recording))\(suffix).wav", build: load)
    }

    static func archive(
        _ recording: Recording,
        build: @escaping @Sendable () throws -> Data
    ) -> RecordingExportFile {
        RecordingExportFile(filename: "\(safeName(recording)).stillarchive", build: build)
    }

    private static func safeName(_ recording: Recording) -> String {
        let allowed = recording.title.replacingOccurrences(
            of: "[^A-Za-z0-9 _-]",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        return allowed.isEmpty ? "Recording" : String(allowed.prefix(60))
    }
}
