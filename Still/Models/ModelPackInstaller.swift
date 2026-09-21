import Foundation
import Observation

@MainActor
@Observable
final class ModelPackInstaller {
    enum State: Equatable {
        case needsApproval
        case installing(completedBytes: Int)
        case verifying
        case installed
        case failed(String)
    }

    let pack: ModelPack

    private let root: URL
    private let downloader: ModelFileDownloader
    private let availableMemory: () -> Int
    private let availableStorage: (URL) -> Int?

    private(set) var state: State

    init(
        pack: ModelPack,
        root: URL,
        downloader: ModelFileDownloader,
        availableMemory: @escaping () -> Int = { Int(ProcessInfo.processInfo.physicalMemory) },
        availableStorage: @escaping (URL) -> Int? = ModelPackInstaller.freeBytes
    ) {
        self.pack = pack
        self.root = root
        self.downloader = downloader
        self.availableMemory = availableMemory
        self.availableStorage = availableStorage
        state = Self.isInstalled(pack: pack, root: root) ? .installed : .needsApproval
    }

    var installedDirectory: URL {
        root.appending(path: "\(pack.id)/\(pack.version)", directoryHint: .isDirectory)
    }

    var progress: Double {
        guard case .installing(let completed) = state else {
            return state == .installed ? 1 : 0
        }
        return Double(completed) / Double(pack.totalBytes)
    }

    /// The only entry point that touches the network. Nothing before the user
    /// approves the download makes a request.
    func approveAndInstall() async {
        guard state != .installed else { return }

        do {
            try checkDevice()
            try createRoot()
            try checkStorage()

            var completed = 0
            state = .installing(completedBytes: 0)

            for file in pack.files {
                let destination = installedDirectory.appending(path: file.path)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                if try isIntact(file, at: destination) {
                    completed += file.bytes
                    state = .installing(completedBytes: completed)
                    continue
                }

                try await downloader.download(
                    from: pack.baseURL.appending(path: file.path),
                    resumingInto: destination
                )

                state = .verifying
                guard try FileDigest.sha256(of: destination) == file.sha256 else {
                    try? FileManager.default.removeItem(at: destination)
                    throw ModelPackError.corruptDownload(path: file.path)
                }

                completed += file.bytes
                state = .installing(completedBytes: completed)
            }

            state = .installed
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func checkDevice() throws {
        guard availableMemory() >= pack.minimumMemoryBytes else { throw ModelPackError.deviceUnsupported }
    }

    private func checkStorage() throws {
        guard let free = availableStorage(root) else { return }
        guard free >= pack.totalBytes else {
            throw ModelPackError.insufficientStorage(needed: pack.totalBytes)
        }
    }

    private func createRoot() throws {
        try FileManager.default.createDirectory(at: installedDirectory, withIntermediateDirectories: true)
    }

    private func isIntact(_ file: ModelFile, at url: URL) throws -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
        guard size == file.bytes else { return false }
        return try FileDigest.sha256(of: url) == file.sha256
    }

    /// A launch-time check that stays cheap. The digests were verified when each
    /// file landed, so matching sizes are enough to trust the installed pack.
    nonisolated static func isInstalled(pack: ModelPack, root: URL) -> Bool {
        let directory = root.appending(path: "\(pack.id)/\(pack.version)", directoryHint: .isDirectory)
        return pack.files.allSatisfy { file in
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: directory.appending(path: file.path).path
            )
            return attributes?[.size] as? Int == file.bytes
        }
    }

    nonisolated static func freeBytes(at url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map(Int.init)
    }
}
