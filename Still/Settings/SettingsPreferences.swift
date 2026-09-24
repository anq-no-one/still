import Foundation
import Observation
import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
    case capture
    case audio
    case shortcuts
    case projects
    case vocabulary
    case sync
    case models
    case speakers
    case aiTools
    case access
    case security
    case storage
    case diagnostics
    case appearance
    case pro

    var id: Self { self }

    var isMacOnly: Bool {
        switch self {
        case .capture, .audio, .shortcuts, .aiTools: true
        default: false
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case recording
    case projects
    case intelligence
    case privacy
    case general

    var id: Self { self }

    var allPages: [SettingsPage] {
        switch self {
        case .recording: [.capture, .audio, .shortcuts]
        case .projects: [.projects, .vocabulary, .sync]
        case .intelligence: [.models, .speakers, .aiTools]
        case .privacy: [.access, .security, .storage, .diagnostics]
        case .general: [.appearance, .pro]
        }
    }
}

struct SettingsLayout: Equatable, Sendable {
    let isMac: Bool
    let showsPro: Bool

    @MainActor
    static var current: SettingsLayout {
        #if os(macOS)
        SettingsLayout(isMac: true, showsPro: !Entitlements.everythingIsFree)
        #else
        SettingsLayout(isMac: false, showsPro: !Entitlements.everythingIsFree)
        #endif
    }

    func pages(in section: SettingsSection) -> [SettingsPage] {
        section.allPages.filter(contains)
    }

    var sections: [SettingsSection] {
        SettingsSection.allCases.filter { !pages(in: $0).isEmpty }
    }

    var firstPage: SettingsPage {
        sections.flatMap(pages(in:)).first ?? .appearance
    }

    func contains(_ page: SettingsPage) -> Bool {
        if page.isMacOnly && !isMac { return false }
        if page == .pro && !showsPro { return false }
        return true
    }
}

@MainActor
@Observable
final class SettingsPreferences {
    private enum Key {
        static let appearance = "still.settings.appearance"
        static let page = "still.settings.page"
    }

    let layout: SettingsLayout
    private let defaults: UserDefaults

    var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var page: SettingsPage {
        didSet { defaults.set(page.rawValue, forKey: Key.page) }
    }

    init(defaults: UserDefaults = .standard, layout: SettingsLayout = .current) {
        self.defaults = defaults
        self.layout = layout
        appearance = defaults.string(forKey: Key.appearance).flatMap(AppearancePreference.init) ?? .system
        page = defaults.string(forKey: Key.page)
            .flatMap(SettingsPage.init)
            .flatMap { layout.contains($0) ? $0 : nil }
            ?? layout.firstPage
    }
}
