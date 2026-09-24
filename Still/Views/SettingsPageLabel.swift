#if os(macOS)
import AppKit
#endif
import SwiftUI

extension SettingsPage {
    var title: LocalizedStringKey {
        switch self {
        case .capture: "Capture"
        case .audio: "Audio Input"
        case .shortcuts: "Shortcuts"
        case .projects: "Projects"
        case .vocabulary: "Vocabulary"
        case .sync: "Sync"
        case .models: "Models"
        case .speakers: "Speakers"
        case .aiTools: "AI Tools"
        case .access: "Access"
        case .security: "Keys and Devices"
        case .storage: "Audio and Deletion"
        case .diagnostics: "Diagnostics"
        case .appearance: "Appearance"
        case .transfer: "Transfer Settings"
        case .pro: "Still Pro"
        }
    }

    var systemImage: String {
        switch self {
        case .capture: "record.circle.fill"
        case .audio: "mic.fill"
        case .shortcuts: "command"
        case .projects: "folder.fill"
        case .vocabulary: "character.book.closed.fill"
        case .sync: "arrow.triangle.2.circlepath"
        case .models: "cpu.fill"
        case .speakers: "person.2.wave.2.fill"
        case .aiTools: "sparkles.rectangle.stack.fill"
        case .access: "hand.raised.fill"
        case .security: "key.fill"
        case .storage: "trash.fill"
        case .diagnostics: "stethoscope"
        case .appearance: "circle.lefthalf.filled"
        case .transfer: "arrow.up.arrow.down.circle.fill"
        case .pro: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .capture: .red
        case .audio: .orange
        case .shortcuts: .gray
        case .projects: .orange
        case .vocabulary: .brown
        case .sync: .cyan
        case .models: .blue
        case .speakers: .pink
        case .aiTools: .purple
        case .access: .indigo
        case .security: .gray
        case .storage: .red
        case .diagnostics: .green
        case .appearance: .blue
        case .transfer: .mint
        case .pro: .purple
        }
    }
}

extension SettingsSection {
    var title: LocalizedStringKey {
        switch self {
        case .recording: "Recording"
        case .projects: "Projects and Sync"
        case .intelligence: "Intelligence"
        case .privacy: "Privacy and Security"
        case .general: "General"
        }
    }
}

struct SettingsPageLabel: View {
    let page: SettingsPage

    #if os(macOS)
    @ScaledMetric(relativeTo: .body) private var tileSize = 20
    @ScaledMetric(relativeTo: .body) private var cornerRadius = 5
    #else
    @ScaledMetric(relativeTo: .body) private var tileSize = 29
    @ScaledMetric(relativeTo: .body) private var cornerRadius = 7
    #endif

    var body: some View {
        Label {
            Text(page.title)
        } icon: {
            Image(systemName: page.systemImage)
                .font(.footnote.weight(.semibold))
                .imageScale(.medium)
                .foregroundStyle(.white)
                .frame(width: tileSize, height: tileSize)
                .background(page.tint.gradient, in: .rect(cornerRadius: cornerRadius))
                .accessibilityHidden(true)
        }
    }
}

private struct StillAppearance: ViewModifier {
    let preferences: SettingsPreferences

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .onChange(of: preferences.appearance, initial: true) { _, appearance in
                NSApplication.shared.appearance = appearance.appKitAppearance
            }
        #else
        content
            .preferredColorScheme(preferences.appearance.colorScheme)
        #endif
    }
}

#if os(macOS)
private extension AppearancePreference {
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
#endif

extension View {
    func stillAppearance(_ preferences: SettingsPreferences) -> some View {
        modifier(StillAppearance(preferences: preferences))
    }
}
