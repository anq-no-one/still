import SwiftUI

struct DiagnosticsSettingsView: View {
    let diagnostics: Diagnostics

    @State private var exported: URL?
    @State private var isMovingExport = false
    @State private var exportProblem: String?

    private var journal: DiagnosticJournal {
        diagnostics.journal
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Size", value: Int64(journal.storedBytes), format: .byteCount(style: .file))
                Button("Export Journal as Text", systemImage: "square.and.arrow.up", action: export)
                if let problem = journal.writeProblem ?? exportProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Journal on This Device")
            } footer: {
                Text("Still keeps a 90-day journal of what it did and what failed, on this device only. It holds event names, versions, and error numbers — never audio, transcripts, names, file paths, or keys.")
            }

            Section {
                Toggle("Share Diagnostics", isOn: enabled)
            } footer: {
                Text("If you turn this on, Still reports only the name of what failed, its version, and the kind of device — never audio, transcripts, notes, searches, or keys. You can turn it off again at any time.")
            }

            Section("What a Report Contains") {
                ForEach(DiagnosticEvent.allCases, id: \.self) { event in
                    Text(event.rawValue)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Diagnostics")
        .fileMover(isPresented: $isMovingExport, file: exported) { result in
            if case .failure(let error) = result {
                exportProblem = error.localizedDescription
            }
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { diagnostics.isEnabled },
            set: { $0 ? diagnostics.enable() : diagnostics.disable() }
        )
    }

    private func export() {
        let name = "Still Journal \(Date.now.formatted(.iso8601.year().month().day())).txt"
        let url = URL.temporaryDirectory.appending(path: name)
        do {
            try journal.export(to: url)
            exported = url
            exportProblem = nil
            isMovingExport = true
        } catch {
            exportProblem = error.localizedDescription
        }
    }
}
