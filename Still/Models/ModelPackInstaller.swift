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
    private let approval: ModelApprovalStore

    private(set) var state: State

    init(
        pack: ModelPack,
        root: URL,
        downloader: ModelFileDownloader,
        availableMemory: @escaping () -> Int = { Int(ProcessInfo.processInfo.physicalMemory) },
        availableStorage: @escaping (URL) -> Int? = ModelPackInstaller.freeBytes,
        approval: ModelApprovalStore = MemoryModelApprovalStore()
    ) {
        self.pack = pack
        self.root = root
        self.downloader = downloader
        self.availableMemory = availableMemory
        self.availableStorage = availableStorage
        self.approval = approval
        state = Self.isInstalled(pack: pack, root: root) ? .installed : .needsApproval
    }

    var installedDirectory: URL {
        pack.installedDirectory(in: root)
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
        approval.markApproved(pack)

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
                    from: pack.remoteURL(of: file),
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

    var isApproved: Bool {
        approval.isApproved(pack)
    }

    /// Picks up a download the user approved before the app quit or the network dropped.
    func resumeIfApproved() async {
        guard isApproved, state != .installed else { return }
        if case .installing = state { return }
        if state == .verifying { return }
        await approveAndInstall()
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
        let directory = pack.installedDirectory(in: root)
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
