import SwiftUI

struct PrivacyWelcomeView: View {
    let startRecording: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Your meetings stay here", systemImage: "lock.shield")
        } description: {
            Text("Still transcribes and stores meetings on this device. It has no account, analytics, or network service.")
        } actions: {
            Button("Record a meeting", systemImage: "record.circle", action: startRecording)
                .buttonStyle(.borderedProminent)
        }
    }
}

