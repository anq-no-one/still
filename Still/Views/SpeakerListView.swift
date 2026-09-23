import SwiftUI

struct SpeakerListView: View {
    let speakers: [Speaker]
    let suggestions: [String]
    let rename: (Speaker, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speakers")
                .font(.headline)

            ForEach(speakers) { speaker in
                SpeakerRow(speaker: speaker, suggestions: speaker.isUnnamedGuest ? suggestions : []) {
                    rename(speaker, $0)
                }
            }
        }
    }
}

private struct SpeakerRow: View {
    let speaker: Speaker
    let suggestions: [String]
    let rename: (String) -> Void

    @State private var name: String
    @FocusState private var isEditing: Bool

    init(speaker: Speaker, suggestions: [String], rename: @escaping (String) -> Void) {
        self.speaker = speaker
        self.suggestions = suggestions
        self.rename = rename
        _name = State(initialValue: speaker.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            field
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                name = suggestion
                                rename(suggestion)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityHint("Names this speaker \(suggestion)")
                        }
                    }
                }
            }
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)

            TextField("Speaker name", text: $name)
                .textFieldStyle(.plain)
                .accessibilityLabel("Name for this speaker")
                .focused($isEditing)
                .onChange(of: isEditing) { _, editing in
                    if !editing, !name.isEmpty { rename(name) }
                }

            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var icon: String {
        speaker.isYou ? "person.fill" : speaker.nameSource == .track ? "person.2" : "person"
    }

    private var caption: LocalizedStringKey? {
        if speaker.isYou { return "Your microphone" }
        switch speaker.nameSource {
        case .voiceProfile: return "Recognized by voice"
        case .calendar: return "From your calendar"
        default: return nil
        }
    }
}
