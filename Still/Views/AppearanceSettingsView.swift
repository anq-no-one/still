import SwiftUI

struct AppearanceSettingsView: View {
    @Bindable var preferences: SettingsPreferences

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(AppearancePreference.allCases) { appearance in
                        Label(appearance.title, systemImage: appearance.systemImage)
                            .tag(appearance)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows the light or dark setting of this device.")
            }
        }
        .formStyle(.grouped)
        .settingsPaneTitle("Appearance")
    }
}

private extension AppearancePreference {
    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}
