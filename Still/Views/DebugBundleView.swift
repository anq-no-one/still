import SwiftUI

/// TestFlight-only developer tooling, so its text is English and stays out of
/// the translated string catalog.
struct DebugBundleView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case given
        case latest
        case lastFive
        case all
        case none

        var id: String { rawValue }
    }

    let builder: DebugBundleBuilder
    let library: Library
    let givenRecordingID: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope
    @State private var includesAudio = true
    @State private var step: String?
    @State private var bundle: URL?
    @State private var problem: String?
    @State private var isSaving = false

    init(builder: DebugBundleBuilder, library: Library, recordingID: UUID? = nil) {
        self.builder = builder
        self.library = library
        givenRecordingID = recordingID
        _scope = State(initialValue: recordingID == nil ? .latest : .given)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String("Recordings"), selection: $scope) {
                        ForEach(scopes) { scope in
                            Text(verbatim: label(scope)).tag(scope)
                        }
                    }
                    Toggle(String("Include original audio tracks"), isOn: $includesAudio)
                } footer: {
                    Text(verbatim: "The bundle holds the developer log, timings, main-thread hangs, CPU and memory samples, MetricKit reports, this launch's system log, and for each recording its original audio tracks, transcript, note, extracted memory and every on-device model prompt and answer. It stays on this device until you share it.")
                }

                Section {
                    if let step {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(verbatim: step)
                        }
                        .accessibilityElement(children: .combine)
                    } else if let bundle {
                        LabeledContent(String("Ready"), value: Int64(size(of: bundle)), format: .byteCount(style: .file))
                        ShareLink(item: bundle, preview: SharePreview(bundle.lastPathComponent)) {
                            Label(String("Share Debug Bundle"), systemImage: "square.and.arrow.up")
                        }
                        Button(String("Save to Files…"), systemImage: "folder") { isSaving = true }
                    } else {
                        Button(String("Prepare Debug Bundle"), systemImage: "ladybug", action: prepare)
                    }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String("Debug Bundle"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String("Done")) { dismiss() }
                }
            }
            .onChange(of: scope) { bundle = nil }
            .onChange(of: includesAudio) { bundle = nil }
            .fileMover(isPresented: $isSaving, file: bundle) { result in
                if case .failure(let error) = result { problem = error.localizedDescription }
                bundle = nil
            }
        }
        .perfScreen("debugBundle")
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }

    private var scopes: [Scope] {
        Scope.allCases.filter { $0 != .given || givenRecordingID != nil }
    }

    private func label(_ scope: Scope) -> String {
        switch scope {
        case .given: "This recording"
        case .latest: "Latest recording"
        case .lastFive: "Last 5 recordings"
        case .all: "All \(library.recordingsInEveryProject.count) recordings"
        case .none: "Logs only"
        }
    }

    private var recordingIDs: [UUID] {
        let newest = library.recordingsInEveryProject.sorted { $0.createdAt > $1.createdAt }.map(\.id)
        switch scope {
        case .given: return givenRecordingID.map { [$0] } ?? []
        case .latest: return Array(newest.prefix(1))
        case .lastFive: return Array(newest.prefix(5))
        case .all: return newest
        case .none: return []
        }
    }

    private func prepare() {
        problem = nil
        step = "Starting"
        let request = DebugBundleRequest(recordingIDs: recordingIDs, includesAudio: includesAudio)
        Task {
            do {
                bundle = try await builder.build(request) { step = $0 }
            } catch {
                problem = error.localizedDescription
                DevLog.error("debugBundle.failed", error)
            }
            step = nil
        }
    }

    private func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

struct DebugBundleButton: View {
    let diagnostics: Diagnostics
    let library: Library
    var recordingID: UUID?

    @State private var isPresented = false

    var body: some View {
        if let builder = diagnostics.debugBundleBuilder(library: library) {
            Button(String("Debug Bundle"), systemImage: "ladybug") {
                Interactions.begin("debugBundle.open")
                isPresented = true
            }
            .help(String("Share logs, timings, audio and AI results with the developer"))
            .sheet(isPresented: $isPresented) {
                DebugBundleView(builder: builder, library: library, recordingID: recordingID)
            }
        }
    }
}
