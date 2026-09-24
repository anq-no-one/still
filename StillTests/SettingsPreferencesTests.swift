import Foundation
import SwiftUI
import Testing
@testable import Still

@MainActor
struct SettingsPreferencesTests {
    private let mac = SettingsLayout(isMac: true, showsPro: false)
    private let phone = SettingsLayout(isMac: false, showsPro: false)

    @Test
    func startsWithTheSystemAppearanceAndTheFirstPage() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))

        let preferences = SettingsPreferences(defaults: defaults, layout: mac)

        #expect(preferences.appearance == .system)
        #expect(preferences.page == .capture)
    }

    @Test
    func remembersTheAppearanceAndPageAcrossLaunches() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let first = SettingsPreferences(defaults: defaults, layout: mac)

        first.appearance = .dark
        first.page = .models
        let second = SettingsPreferences(defaults: defaults, layout: mac)

        #expect(second.appearance == .dark)
        #expect(second.page == .models)
    }

    @Test
    func aPageThisDeviceDoesNotShowFallsBackToTheFirstPage() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        SettingsPreferences(defaults: defaults, layout: mac).page = .shortcuts

        let preferences = SettingsPreferences(defaults: defaults, layout: phone)

        #expect(preferences.page == .projects)
    }

    @Test
    func anUnknownStoredValueFallsBackToTheDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("sepia", forKey: "still.settings.appearance")
        defaults.set("retired-page", forKey: "still.settings.page")

        let preferences = SettingsPreferences(defaults: defaults, layout: mac)

        #expect(preferences.appearance == .system)
        #expect(preferences.page == .capture)
    }

    @Test
    func appearanceMapsToAColorSchemeOnlyWhenChosen() {
        #expect(AppearancePreference.system.colorScheme == nil)
        #expect(AppearancePreference.light.colorScheme == .light)
        #expect(AppearancePreference.dark.colorScheme == .dark)
    }

    @Test
    func everyPageBelongsToExactlyOneSection() {
        let grouped = SettingsSection.allCases.flatMap(\.allPages)

        #expect(grouped.count == Set(grouped).count)
        #expect(Set(grouped) == Set(SettingsPage.allCases))
    }

    @Test
    func theMacShowsEveryGroupTheSpecNames() {
        let pages = mac.sections.flatMap(mac.pages(in:))

        #expect(mac.sections == [.recording, .projects, .intelligence, .privacy, .general])
        for page: SettingsPage in [.capture, .audio, .vocabulary, .models, .projects, .sync, .security, .diagnostics, .shortcuts, .appearance] {
            #expect(pages.contains(page))
        }
        #expect(!pages.contains(.pro))
    }

    @Test
    func iPhoneAndIPadHideMacOnlyPagesButKeepKeysAndDeletion() {
        let pages = phone.sections.flatMap(phone.pages(in:))

        #expect(!phone.sections.contains(.recording))
        #expect(pages.allSatisfy { !$0.isMacOnly })
        #expect(pages.contains(.security))
        #expect(pages.contains(.storage))
        #expect(pages.contains(.models))
    }

    @Test
    func stillProAppearsOnlyWhenItIsSold() {
        let selling = SettingsLayout(isMac: true, showsPro: true)

        #expect(selling.pages(in: .general).contains(.pro))
        #expect(!mac.pages(in: .general).contains(.pro))
    }
}

struct ModelLanguageTests {
    @Test
    func speechRecognitionCoversTheTwentyFiveParakeetLanguages() {
        guard case .only(let codes) = ModelCatalog.parakeetV3.languages else {
            Issue.record("Speech recognition must list its languages")
            return
        }

        #expect(codes.count == 25)
        #expect(Set(codes).count == 25)
        for verified in ["en", "pl", "ru", "uk", "de", "fr", "es", "it"] {
            #expect(codes.contains(verified))
        }
    }

    @Test
    func languageNamesResolveAndSortForTheReader() {
        let names = ModelCatalog.parakeetV3.languages.names(in: Locale(identifier: "en_US"))

        #expect(names.count == 25)
        #expect(names.first == "Bulgarian")
        #expect(names.contains("Ukrainian"))
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test
    func languageNamesFollowTheInterfaceLanguage() {
        let names = ModelCatalog.parakeetV3.languages.names(in: Locale(identifier: "de_DE"))

        #expect(names.contains("Deutsch"))
        #expect(names.contains("Englisch"))
    }

    @Test
    func speakerSeparationWorksWithAnyLanguage() {
        #expect(ModelCatalog.speakerSeparation.languages == .any)
        #expect(ModelCatalog.speakerSeparation.languages.names().isEmpty)
    }

    @Test
    func everyPackHasANameAndPurpose() {
        for pack in [ModelCatalog.parakeetV3, ModelCatalog.speakerSeparation, ModelCatalog.meetingMemorySmall, ModelCatalog.meetingMemoryLarge] {
            #expect(!pack.name.isEmpty)
            #expect(!pack.purpose.isEmpty)
        }
    }
}
