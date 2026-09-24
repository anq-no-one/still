import SwiftUI

struct SpeakerListView: View {
    let speakers: [Speaker]
    let suggestions: [String]
    let rename: (Speaker, String) -> Void
    let confirmSuggestedName: (Speaker) -> Void
    let rejectSuggestedName: (Speaker) -> Void
    var remembersVoice: (Speaker) -> Bool = { _ in false }
    var setRemembersVoice: (Speaker, Bool) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speakers")
                .font(.headline)

            ForEach(speakers) { speaker in
                SpeakerRow(
                    speaker: speaker,
                    suggestions: speaker.isUnnamedGuest ? suggestions : [],
                    rename: { rename(speaker, $0) },
                    confirmSuggestedName: { confirmSuggestedName(speaker) },
                    rejectSuggestedName: { rejectSuggestedName(speaker) },
                    remembersVoice: remembersVoice(speaker),
                    setRemembersVoice: { setRemembersVoice(speaker, $0) }
                )
            }
        }
    }
}

private struct SpeakerRow: View {
    let speaker: Speaker
    let suggestions: [String]
    let rename: (String) -> Void
    let confirmSuggestedName: () -> Void
    let rejectSuggestedName: () -> Void
    let remembersVoice: Bool
    let setRemembersVoice: (Bool) -> Void

    @State private var name: String
    @FocusState private var isEditing: Bool

    init(
        speaker: Speaker,
        suggestions: [String],
        rename: @escaping (String) -> Void,
        confirmSuggestedName: @escaping () -> Void,
        rejectSuggestedName: @escaping () -> Void,
        remembersVoice: Bool,
        setRemembersVoice: @escaping (Bool) -> Void
    ) {
        self.speaker = speaker
        self.suggestions = suggestions
        self.rename = rename
        self.confirmSuggestedName = confirmSuggestedName
        self.rejectSuggestedName = rejectSuggestedName
        self.remembersVoice = remembersVoice
        self.setRemembersVoice = setRemembersVoice
        _name = State(initialValue: speaker.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            field
            if let suggested = speaker.suggestedName {
                suggestedName(suggested)
            }
            if speaker.isNamedByUser, !speaker.isYou, speaker.voiceprint != nil {
                voiceMemory
            }
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

    private func suggestedName(_ suggested: String) -> some View {
        HStack(spacing: 8) {
            Label("\(suggested)?", systemImage: "person.wave.2")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Suggested name from the call: \(suggested)")

            Spacer(minLength: 0)

            Button("Confirm") {
                name = suggested
                confirmSuggestedName()
            }
            .accessibilityLabel("Confirm \(suggested)")
            .accessibilityHint("Names this speaker \(suggested)")

            Button("Reject") {
                rejectSuggestedName()
            }
            .accessibilityLabel("Reject \(suggested)")
            .accessibilityHint("Keeps the current name and drops the suggestion")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var voiceMemory: some View {
        Toggle(isOn: Binding(get: { remembersVoice }, set: setRemembersVoice)) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remember \(speaker.name)'s Voice")
                Text("Still suggests this name when the voice returns in a later meeting. You confirm each time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
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
        case .callCue: return "From the call"
        default: return nil
        }
    }
}
