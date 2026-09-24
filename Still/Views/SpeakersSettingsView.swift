import SwiftUI

struct SpeakersSettingsView: View {
    let library: Library

    @State private var ownerName = ""
    @State private var ownerNameFailure: String?

    var body: some View {
        Form {
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
        .onAppear { ownerName = library.ownerName ?? "" }
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
