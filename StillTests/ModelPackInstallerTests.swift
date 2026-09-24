import CryptoKit
import Foundation
import Testing
@testable import Still

@MainActor
struct ModelPackInstallerTests {
    @Test
    func makesNoRequestBeforeApproval() throws {
        let scratch = try Scratch()
        let downloader = FakeDownloader(pack: .sample)
        let installer = makeInstaller(root: scratch.directory, downloader: downloader)

        #expect(installer.state == .needsApproval)
        #expect(downloader.requests.isEmpty)
        #expect(installer.pack.downloadSizeText.isEmpty == false)
        #expect(installer.pack.purpose.isEmpty == false)
    }

    @Test
    func installsAndVerifiesEveryFile() async throws {
        let scratch = try Scratch()
        let installer = makeInstaller(root: scratch.directory, downloader: FakeDownloader(pack: .sample))

        await installer.approveAndInstall()

        #expect(installer.state == .installed)
        #expect(installer.progress == 1)
        for file in ModelPack.sample.files {
            let url = installer.installedDirectory.appending(path: file.path)
            #expect(try FileDigest.sha256(of: url) == file.sha256)
        }
    }

    @Test
    func resumesAnInterruptedDownloadWithoutRestarting() async throws {
        let scratch = try Scratch()
        let downloader = FakeDownloader(pack: .sample)
        downloader.failAfterBytes = 4
        let installer = makeInstaller(root: scratch.directory, downloader: downloader)

        await installer.approveAndInstall()
        #expect(installer.state == .failed(ModelPackError.offline.localizedDescription))

        downloader.failAfterBytes = nil
        await installer.approveAndInstall()

        #expect(installer.state == .installed)
        #expect(downloader.resumedOffsets.contains(4))
    }

    @Test
    func removesACorruptDownloadAndSaysSo() async throws {
        let scratch = try Scratch()
        let downloader = FakeDownloader(pack: .sample)
        downloader.corruptsFirstFile = true
        let installer = makeInstaller(root: scratch.directory, downloader: downloader)

        await installer.approveAndInstall()

        let corrupted = ModelPack.sample.files[0]
        #expect(installer.state == .failed(ModelPackError.corruptDownload(path: corrupted.path).localizedDescription))
        #expect(!FileManager.default.fileExists(atPath: installer.installedDirectory.appending(path: corrupted.path).path))
    }

    @Test
    func refusesADeviceWithTooLittleMemory() async throws {
        let scratch = try Scratch()
        let downloader = FakeDownloader(pack: .sample)
        let installer = makeInstaller(
            root: scratch.directory,
            downloader: downloader,
            memory: ModelPack.sample.minimumMemoryBytes - 1
        )

        await installer.approveAndInstall()

        #expect(installer.state == .failed(ModelPackError.deviceUnsupported.localizedDescription))
        #expect(downloader.requests.isEmpty)
    }

    @Test
    func refusesToFillTheDisk() async throws {
        let scratch = try Scratch()
        let downloader = FakeDownloader(pack: .sample)
        let installer = makeInstaller(root: scratch.directory, downloader: downloader, freeBytes: 1)

        await installer.approveAndInstall()

        let expected = ModelPackError.insufficientStorage(needed: ModelPack.sample.totalBytes)
        #expect(installer.state == .failed(expected.localizedDescription))
        #expect(downloader.requests.isEmpty)
    }

    @Test
    func anInstalledPackNeedsNoNetworkOnTheNextLaunch() async throws {
        let scratch = try Scratch()
        await makeInstaller(root: scratch.directory, downloader: FakeDownloader(pack: .sample)).approveAndInstall()

        let relaunched = FakeDownloader(pack: .sample)
        let installer = makeInstaller(root: scratch.directory, downloader: relaunched)

        #expect(installer.state == .installed)

        await installer.approveAndInstall()

        #expect(relaunched.requests.isEmpty)
    }

    @Test
    func resumingWithoutApprovalMakesNoRequest() async throws {
        let scratch = try Scratch()
        let downloader = FakeDownloader(pack: .sample)
        let installer = makeInstaller(root: scratch.directory, downloader: downloader)

        await installer.resumeIfApproved()

        #expect(installer.state == .needsApproval)
        #expect(downloader.requests.isEmpty)
    }

    @Test
    func aDownloadInterruptedByQuittingFinishesAfterRelaunchWithoutAskingAgain() async throws {
        let scratch = try Scratch()
        let approval = MemoryModelApprovalStore()
        let downloader = FakeDownloader(pack: .sample)
        downloader.failAfterBytes = 4
        let first = makeInstaller(root: scratch.directory, downloader: downloader, approval: approval)
        await first.approveAndInstall()
        #expect(first.state != .installed)

        downloader.failAfterBytes = nil
        let relaunched = makeInstaller(root: scratch.directory, downloader: downloader, approval: approval)
        #expect(relaunched.state == .needsApproval)
        #expect(relaunched.isApproved)

        await relaunched.resumeIfApproved()

        #expect(relaunched.state == .installed)
        #expect(downloader.resumedOffsets.contains(4))
    }

    private func makeInstaller(
        root: URL,
        downloader: ModelFileDownloader,
        memory: Int = ModelPack.sample.minimumMemoryBytes,
        freeBytes: Int = 1 << 30,
        approval: ModelApprovalStore = MemoryModelApprovalStore()
    ) -> ModelPackInstaller {
        ModelPackInstaller(
            pack: .sample,
            root: root,
            downloader: downloader,
            availableMemory: { memory },
            availableStorage: { _ in freeBytes },
            approval: approval
        )
    }
}

extension ModelPack {
    static let sample: ModelPack = {
        let contents = ["first-file-bytes", "second", "third-file-payload"]
        let files = contents.enumerated().map { index, text in
            ModelFile(
                path: "part\(index)/weights.bin",
                bytes: text.utf8.count,
                sha256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            )
        }
        return ModelPack(
            id: "sample-pack",
            name: "Sample",
            purpose: "Turns speech into text on this device.",
            languages: .only(["en"]),
            version: "v1",
            baseURL: URL(string: "https://example.invalid/pack/")!,
            minimumMemoryBytes: 4_000,
            files: files
        )
    }()

    static let sampleContents = ["first-file-bytes", "second", "third-file-payload"]
}

final class FakeDownloader: ModelFileDownloader, @unchecked Sendable {
    private let pack: ModelPack

    var failAfterBytes: Int?
    var corruptsFirstFile = false
    private(set) var requests: [URL] = []
    private(set) var resumedOffsets: [Int] = []

    init(pack: ModelPack) {
        self.pack = pack
    }

    func download(from url: URL, resumingInto destination: URL) async throws {
        requests.append(url)

        let index = pack.files.firstIndex { url.path().hasSuffix($0.path) } ?? 0
        var payload = Data(ModelPack.sampleContents[index].utf8)
        if corruptsFirstFile, index == 0 {
            payload = Data("corrupted-payload".utf8)
        }

        let existing = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int) ?? 0
        resumedOffsets.append(existing)

        var slice = payload.dropFirst(existing)
        if let failAfterBytes, existing < failAfterBytes {
            slice = payload[existing..<failAfterBytes]
        }

        if existing == 0 {
            try Data(slice).write(to: destination, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(slice))
        }

        if failAfterBytes != nil, existing < (failAfterBytes ?? 0) {
            throw ModelPackError.offline
        }
    }
}
