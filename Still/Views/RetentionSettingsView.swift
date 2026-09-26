import SwiftUI

struct RetentionSettingsView: View {
    let library: Library

    @State private var policy: RetentionPolicy
    @State private var failure: String?

    init(library: Library) {
        self.library = library
        _policy = State(initialValue: library.retentionPolicy)
    }

    var body: some View {
        Form {
            Section {
                Picker("Keep Audio", selection: $policy) {
                    ForEach(RetentionPolicy.allCases, id: \.self) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.inline)
                .onChange(of: policy) { _, value in
                    library.retentionPolicy = value
                    apply()
                }
            } header: {
                Text("Keep Audio")
            } footer: {
                Text("Deleting a recording keeps it recoverable for 30 days before Still removes it for good, on this device and on the ones it syncs with.")
            }

            if !library.deletedRecordings.isEmpty {
                Section("Recently Deleted") {
                    ForEach(library.deletedRecordings) { recording in
                        LabeledContent(recording.title) {
                            Button("Restore") { restore(recording) }
                        }
                    }
                }
            }

            if !library.archivedRecordings.isEmpty {
                Section("Archived") {
                    ForEach(library.archivedRecordings) { recording in
                        LabeledContent(recording.title) {
                            Button("Unarchive") { unarchive(recording) }
                        }
                    }
                }
            }

            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Audio and Deletion")
    }

    private func apply() {
        do {
            try library.applyRetention()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func restore(_ recording: Recording) {
        do {
            try library.restore(recording)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func unarchive(_ recording: Recording) {
        do {
            try library.unarchive(recording)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
