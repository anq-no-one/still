import SwiftUI

struct SpeakersSettingsView: View {
    let library: Library
    var tileSettings: MeetingTileSettingsStore = UserDefaultsMeetingTileSettings()

    @State private var ownerName = ""
    @State private var ownerNameFailure: String?
    @State private var identifiesTiles = true

    var body: some View {
        Form {
            #if os(macOS)
            Section {
                Toggle("Identify Speakers from the Meeting Window", isOn: $identifiesTiles)
                    .onChange(of: identifiesTiles) { _, enabled in tileSettings.setEnabled(enabled) }
            } header: {
                Text("Meeting Window")
            } footer: {
                Text("While a call app plays sound, Still photographs only the meeting window when someone is speaking. On-device text reading suggests names for that recording, then the photographs are deleted. They never leave this Mac. Needs the Screen Recording permission you already granted for call audio. Turn this off to rely on calendar, voice and manual names only.")
            }
            #endif

            Section {
                TextField("Your Name", text: $ownerName, prompt: Text("First and last name"))
                    .onSubmit(saveOwnerName)
                if let ownerNameFailure {
                    Label(ownerNameFailure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("You")
            } footer: {
                Text("Still suggests this name for your own voice in recordings.")
            }

            Section {
                if library.rememberedVoiceProfiles.isEmpty {
                    Text("No voices remembered")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.rememberedVoiceProfiles, id: \.name) { profile in
                    LabeledContent(profile.name) {
                        Button("Forget", role: .destructive) {
                            try? library.forgetVoice(of: profile.name)
                        }
                    }
                }
            } header: {
                Text("Remembered Voices")
            } footer: {
                Text("Still remembers a voice only when you turn it on for a named speaker. A remembered voice only suggests a name; you confirm it. Forgetting stops all future suggestions.")
            }
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Speakers")
        .onAppear {
            ownerName = library.ownerName ?? ""
            identifiesTiles = tileSettings.isEnabled()
        }
        .onDisappear(perform: saveOwnerName)
    }

    private func saveOwnerName() {
        guard ownerName != (library.ownerName ?? "") else { return }
        do {
            try library.setOwnerName(ownerName)
            ownerNameFailure = nil
        } catch {
            ownerNameFailure = error.localizedDescription
        }
    }
}
