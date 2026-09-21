import SwiftUI

struct MeetingDetailView: View {
    @Bindable var meeting: Meeting

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TextField("Meeting title", text: $meeting.title)
                    .font(.largeTitle.bold())
                    .textFieldStyle(.plain)

                HStack(spacing: 14) {
                    Label(meeting.createdAt.formatted(date: .long, time: .shortened), systemImage: "calendar")
                    Label(meeting.duration.meetingDurationText, systemImage: "clock")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Divider()

                Text(meeting.transcript)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(meeting.title)
    }
}
