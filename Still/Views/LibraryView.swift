import SwiftUI

struct LibraryView: View {
    let library: Library

    @State private var selection: Recording.ID?
    @State private var isCapturing = false
    @State private var actionError: String?

    var body: some View {
        NavigationSplitView {
            List(library.recordings, selection: $selection) { recording in
                RecordingRow(recording: recording)
                    .tag(recording.id)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            delete(recording)
                        }
                    }
            }
            .navigationTitle("Recordings")
            .overlay {
                emptyState
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Record", systemImage: "record.circle") {
                        isCapturing = true
                    }
                    .disabled(library.state != .unlocked)
                }
            }
        } detail: {
            if let recording = selected {
                RecordingDetailView(recording: recording, library: library)
                    .id(recording.id)
            } else {
                PrivacyWelcomeView(startRecording: { isCapturing = true })
            }
        }
        .sheet(isPresented: $isCapturing) {
            CaptureView(library: library)
        }
        .alert("Still could not finish that", isPresented: showsActionError) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .task {
            await library.unlock()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch library.state {
        case .locked, .unlocking:
            ContentUnavailableView(
                "Library locked",
                systemImage: "lock.fill",
                description: Text("Authenticate to open your recordings.")
            )
        case .failed(let message):
            ContentUnavailableView {
                Label("Library locked", systemImage: "lock.trianglebadge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") {
                    Task { await library.unlock() }
                }
            }
        case .unlocked where library.recordings.isEmpty:
            ContentUnavailableView(
                "No recordings yet",
                systemImage: "waveform",
                description: Text("Record your first private, on-device transcript.")
            )
        case .unlocked:
            EmptyView()
        }
    }

    private var selected: Recording? {
        library.recordings.first { $0.id == selection }
    }

    private var showsActionError: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    private func delete(_ recording: Recording) {
        do {
            if selection == recording.id { selection = nil }
            try library.delete(recording)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(recording.title)
                .font(.headline)
                .lineLimit(2)

            HStack {
                Text(recording.createdAt, format: .dateTime.day().month().hour().minute())
                Spacer()
                Text(recording.duration.recordingDurationText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
