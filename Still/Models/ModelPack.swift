import Foundation

struct ModelFile: Equatable, Sendable {
    let path: String
    let bytes: Int
    let sha256: String
    let source: URL?

    init(path: String, bytes: Int, sha256: String, source: URL? = nil) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
        self.source = source
    }
}

enum ModelLanguages: Equatable, Sendable {
    case any
    case only([String])

    func names(in locale: Locale = .current) -> [String] {
        guard case .only(let codes) = self else { return [] }
        return codes
            .compactMap { locale.localizedString(forLanguageCode: $0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

struct ModelPack: Equatable, Sendable {
    let id: String
    let name: String
    let purpose: String
    let languages: ModelLanguages
    let version: String
    let baseURL: URL
    let minimumMemoryBytes: Int
    let files: [ModelFile]

    func remoteURL(of file: ModelFile) -> URL {
        (file.source ?? baseURL).appending(path: file.path)
    }

    func installedDirectory(in root: URL) -> URL {
        root.appending(path: "\(id)/\(version)", directoryHint: .isDirectory)
    }

    var totalBytes: Int {
        files.reduce(0) { $0 + $1.bytes }
    }

    var downloadSizeText: String {
        ByteCountFormatStyle(style: .file).format(Int64(totalBytes))
    }
}

enum ModelPackError: LocalizedError, Equatable {
    case deviceUnsupported
    case insufficientStorage(needed: Int)
    case offline
    case corruptDownload(path: String)

    var errorDescription: String? {
        switch self {
        case .deviceUnsupported:
            return "This device does not have enough memory to transcribe on device."
        case .insufficientStorage(let needed):
            let size = ByteCountFormatStyle(style: .file).format(Int64(needed))
            return "Still needs \(size) free to install speech recognition. Free some space and try again."
        case .offline:
            return "Still could not reach the download. It will resume where it stopped when you are back online."
        case .corruptDownload:
            return "Part of the download did not arrive intact. Still removed it and can try again."
        }
    }
}
