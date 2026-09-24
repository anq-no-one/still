import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct PreferencesExportFile: Transferable, Sendable {
    let build: @Sendable () throws -> Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            let url = URL.temporaryDirectory.appending(path: "Still Settings.json")
            try file.build().write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
