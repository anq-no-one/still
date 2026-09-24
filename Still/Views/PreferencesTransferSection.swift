import SwiftUI
import UniformTypeIdentifiers

struct PreferencesTransferSection: View {
    let exporter: PreferencesExporter
    let importer: PreferencesImporter

    @State private var isImporting = false
    @State private var summary: String?
    @State private var failure: String?

    var body: some View {
        Section {
            ShareLink("Export Settings…", item: exportFile, preview: SharePreview("Still Settings"))
            Button("Import Settings…") {
                summary = nil
                failure = nil
                isImporting = true
            }
            if let summary {
                Text(summary)
                    .foregroundStyle(.secondary)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Transfer Settings")
        } footer: {
            Text("Moves project vocabulary, the shortcut, and ordinary preferences to another device. Keys, permissions, and consents never leave this device.")
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json], onCompletion: handleImport)
    }

    private var exportFile: PreferencesExportFile {
        let file = exporter.export()
        return PreferencesExportFile { try PreferencesCoder.encode(file) }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let data = try Data(contentsOf: url)
            let outcome = try importer.apply(data)
            summary = Self.describe(outcome)
            failure = nil
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            summary = nil
        }
    }

    private static func describe(_ summary: PreferencesImporter.Summary) -> String {
        var appliedCount = 0
        if summary.appliedRetentionPolicy { appliedCount += 1 }
        if summary.appliedAppLockTimeout { appliedCount += 1 }
        if summary.appliedAutomaticRecording { appliedCount += 1 }
        if summary.appliedMeetingSites { appliedCount += 1 }
        if summary.appliedMediaHint { appliedCount += 1 }
        if summary.appliedMicrophone { appliedCount += 1 }
        if summary.appliedShortcut { appliedCount += 1 }

        switch (appliedCount, summary.vocabularyProjectCount) {
        case (0, 0):
            return String(localized: "Nothing in this file applied to this device.")
        case (0, let projects):
            return String(localized: "Imported vocabulary for \(projects) project(s).")
        case (let preferences, 0):
            return String(localized: "Imported \(preferences) preference(s).")
        case (let preferences, let projects):
            return String(localized: "Imported \(preferences) preference(s) and vocabulary for \(projects) project(s).")
        }
    }
}
