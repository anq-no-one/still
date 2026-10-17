import Foundation
import Testing
@testable import Still

/// Proves where network access can live. Every file that can reach the network
/// is named here, so a new one shows up as a failing test rather than as
/// traffic nobody expected.
struct NetworkBoundaryTests {
    private static let approvedFiles: [String: String] = [
        "ModelFileDownloader.swift": "Model pack download, only after the user approves it",
        "CloudKitSyncTransport.swift": "iCloud sync, only after the user turns it on",
        "NetworkNearbySession.swift": "Direct device sync, only after pairing",
        "StoreKitEntitlementSource.swift": "App Store purchase and restore",
        "StillApp.swift": "Composition root: names the transports above, calls none of them",
    ]

    private static let networkSymbols = [
        "URLSession",
        "NWConnection",
        "NWListener",
        "NWBrowser",
        "CKContainer",
        "CKDatabase",
        "Product.products",
        "AppStore.sync",
    ]

    @Test
    func onlyApprovedFilesCanReachTheNetwork() throws {
        var unexpected: [String] = []

        for file in try swiftFiles() {
            let name = file.lastPathComponent
            guard Self.approvedFiles[name] == nil else { continue }

            let source = try String(contentsOf: file, encoding: .utf8)
            for symbol in Self.networkSymbols where source.contains(symbol) {
                unexpected.append("\(name) uses \(symbol)")
            }
        }

        #expect(unexpected.isEmpty, "Unapproved network use: \(unexpected.joined(separator: ", "))")
    }

    @Test
    func everyApprovedFileStillExistsAndIsAccountedFor() throws {
        let names = Set(try swiftFiles().map(\.lastPathComponent))

        for approved in Self.approvedFiles.keys {
            #expect(names.contains(approved), "\(approved) is listed as a network path but is gone")
        }
    }

    @Test
    func theLocalJourneyTouchesNoApprovedNetworkPath() throws {
        let local = [
            "RecordingWorkflow.swift",
            "RecordingCoordinator.swift",
            "FinalTranscription.swift",
            "OfflineTranscriber.swift",
            "LibrarySearch.swift",
            "RecordingDocument.swift",
            "AudioChunkStore.swift",
            "Library.swift",
        ]

        for file in try swiftFiles() where local.contains(file.lastPathComponent) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for symbol in Self.networkSymbols {
                #expect(!source.contains(symbol), "\(file.lastPathComponent) reaches the network through \(symbol)")
            }
        }
    }

    private func swiftFiles() throws -> [URL] {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Still")

        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }
}

@MainActor
struct DiagnosticsTests {
    @Test
    func staysOffUntilTheUserTurnsItOn() async {
        let sink = SpyDiagnosticsSink()
        let diagnostics = Diagnostics(settings: MemoryDiagnosticsSettings(), sink: sink)

        #expect(!diagnostics.isEnabled)

        await diagnostics.record(.recordingFailed)

        #expect(sink.reports.isEmpty)
    }

    @Test
    func stopsAgainWhenTheUserChangesTheirMind() async {
        let sink = SpyDiagnosticsSink()
        let diagnostics = Diagnostics(settings: MemoryDiagnosticsSettings(), sink: sink)
        diagnostics.enable()
        await diagnostics.record(.syncFailed)

        diagnostics.disable()
        await diagnostics.record(.syncFailed)

        #expect(sink.reports.count == 1)
    }

    @Test
    func aReportCarriesNothingFromTheLibrary() async throws {
        let sink = SpyDiagnosticsSink()
        let diagnostics = Diagnostics(
            settings: MemoryDiagnosticsSettings(),
            sink: sink,
            environment: { (appVersion: "1.0", systemVersion: "26.0", deviceClass: "mac") },
            now: { Date(timeIntervalSince1970: 0) }
        )
        diagnostics.enable()

        await diagnostics.record(.transcriptionFailed, duration: 12.4)

        let report = try #require(sink.reports.first)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)

        #expect(report.event == .transcriptionFailed)
        #expect(report.durationSeconds == 12)
        #expect(json.contains("transcriptionFailed"))
        #expect(!json.lowercased().contains("transcript\""))
        #expect(Mirror(reflecting: report).children.count == 6)
    }

    @Test
    func everyEventNameComesFromAClosedSet() {
        #expect(DiagnosticEvent.allCases.allSatisfy { !$0.rawValue.isEmpty })
        #expect(DiagnosticEvent(rawValue: "We agreed to delay hiring") == nil)
    }
}

final class SpyDiagnosticsSink: DiagnosticsSink, @unchecked Sendable {
    private(set) var reports: [DiagnosticReport] = []

    func send(_ report: DiagnosticReport) async {
        reports.append(report)
    }
}

final class MemoryDiagnosticsSettings: DiagnosticsSettingsStore, @unchecked Sendable {
    private var enabled = false

    func isEnabled() -> Bool { enabled }
    func setEnabled(_ value: Bool) { enabled = value }
}
