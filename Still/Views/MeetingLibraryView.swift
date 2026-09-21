import SwiftData
import SwiftUI

struct MeetingLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]
    @State private var selectedMeeting: Meeting?
    @State private var isRecording = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedMeeting) {
                ForEach(meetings) { meeting in
                    MeetingRow(meeting: meeting)
                        .tag(meeting)
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Meetings")
            .overlay {
                if meetings.isEmpty {
                    ContentUnavailableView(
                        "No meetings yet",
                        systemImage: "waveform",
                        description: Text("Record your first private, on-device transcript.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Record", systemImage: "record.circle") {
                        isRecording = true
                    }
                }
            }
        } detail: {
            if let selectedMeeting {
                MeetingDetailView(meeting: selectedMeeting)
            } else {
                PrivacyWelcomeView(startRecording: { isRecording = true })
            }
        }
        .sheet(isPresented: $isRecording) {
            RecordingView()
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            if selectedMeeting == meetings[index] {
                selectedMeeting = nil
            }
            modelContext.delete(meetings[index])
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(meeting.title)
                .font(.headline)
                .lineLimit(2)

            HStack {
                Text(meeting.createdAt, format: .dateTime.day().month().hour().minute())
                Spacer()
                Text(meeting.duration.meetingDurationText)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
