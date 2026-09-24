import Foundation

@MainActor
struct PreferencesExporter {
    let library: Library
    let appLock: AppLock
    #if os(macOS)
    let automaticRecording: CallAppAllowList
    let meetingSites: MeetingSiteAllowList
    let mediaHint: MediaHintPreferencesStore
    let microphone: MicrophoneChoiceStore
    let shortcut: ShortcutStore
    #endif

    func export(at date: Date = .now) -> PreferencesFile {
        var file = PreferencesFile(
            exportedAt: date,
            retentionPolicy: library.retentionPolicy,
            appLockTimeout: appLock.timeout,
            vocabularies: vocabularies()
        )

        #if os(macOS)
        file.automaticRecording = AutomaticRecordingPreference(
            allowedBundleIDs: automaticRecording.apps().filter(\.isAllowed).map(\.bundleID),
            watching: automaticRecording.watches
        )
        file.meetingSites = MeetingSitesPreference(
            allowedHosts: meetingSites.sites().filter(\.isAllowed).map(\.host),
            suggestsSpeakerNames: meetingSites.suggestsSpeakerNames
        )
        file.mediaHintOff = mediaHint.isOff
        if let chosen = microphone.chosen {
            file.microphoneUID = chosen.uid
            file.microphoneName = chosen.name
        }
        if let combo = shortcut.load() {
            file.shortcutKeyCode = combo.keyCode
            file.shortcutModifiers = combo.modifiers
            file.shortcutKey = combo.key
        }
        #endif

        return file
    }

    private func vocabularies() -> [VocabularyPreference] {
        library.storedVocabularies.compactMap { vocabulary in
            guard !vocabulary.terms.isEmpty, let project = library.project(withID: vocabulary.projectID) else { return nil }
            return VocabularyPreference(projectID: vocabulary.projectID, projectName: project.name, terms: vocabulary.terms)
        }
    }
}
