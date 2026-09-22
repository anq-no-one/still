import SwiftUI

struct RetentionSettingsView: View {
    let library: Library

    @Environment(\.dismiss) private var dismiss
    @State private var policy: RetentionPolicy
    @State private var failure: String?

    init(library: Library) {
        self.library = library
        _policy = State(initialValue: library.retentionPolicy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Audio and deletion", systemImage: "clock.arrow.circlepath")
                .font(.title2.bold())

            Picker("Keep audio", selection: $policy) {
                ForEach(RetentionPolicy.allCases, id: \.self) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .pickerStyle(.inline)
            .onChange(of: policy) { _, value in
                library.retentionPolicy = value
                apply()
            }

            Text("Deleting a recording keeps it recoverable for 30 days before Still removes it for good, on this device and on the ones it syncs with.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !library.deletedRecordings.isEmpty {
                Text("Recently deleted")
                    .font(.headline)

                ForEach(library.deletedRecordings) { recording in
                    HStack {
                        Text(recording.title)
                            .lineLimit(1)

                        Spacer()

                        Button("Restore") {
                            do {
                                try library.restore(recording)
                            } catch {
                                failure = error.localizedDescription
                            }
                        }
                    }
                }
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .stillSheetWidth(mac: 440)
    }

    private func apply() {
        do {
            try library.applyRetention()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
