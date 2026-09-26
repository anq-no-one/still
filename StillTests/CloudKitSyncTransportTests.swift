import Foundation
import Testing
@testable import Still

struct CloudKitSyncTransportTests {
    @Test
    func developerProfileCountsAsProvisioned() throws {
        let profile = try makeFile()

        #expect(CloudKitSyncTransport.hasCloudKitIdentity(profile: profile, storeReceipt: missing()))
    }

    @Test
    func storeReceiptCountsAsProvisioned() throws {
        let receipt = try makeFile()

        #expect(CloudKitSyncTransport.hasCloudKitIdentity(profile: missing(), storeReceipt: receipt))
    }

    @Test
    func adHocBuildCountsAsUnprovisioned() {
        #expect(!CloudKitSyncTransport.hasCloudKitIdentity(profile: missing(), storeReceipt: missing()))
        #expect(!CloudKitSyncTransport.hasCloudKitIdentity(profile: missing(), storeReceipt: nil))
    }

    private func missing() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).missing")
    }

    private func makeFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).proof")
        try Data("proof".utf8).write(to: url)
        return url
    }
}
