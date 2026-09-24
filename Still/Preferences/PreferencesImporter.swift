import Foundation

@MainActor
struct PreferencesImporter {
    struct Summary: Equatable, Sendable {
        var vocabularyProjectCount = 0
        var appliedRetentionPolicy = false
        var appliedAppLockTimeout = false
        var appliedAutomaticRecording = false
        var appliedMeetingSites = false
        var appliedMediaHint = false
        var appliedMicrophone = false
        var appliedShortcut = false

        var isEmpty: Bool {
            self == Summary()
        }
    }

    let library: Library
    let appLock: AppLock
    #if os(macOS)
    let automaticRecording: CallAppAllowList
    let meetingSites: MeetingSiteAllowList
    let mediaHint: MediaHintPreferencesStore
    let microphone: MicrophoneChoiceStore
    let shortcut: ShortcutStore
    var afterApply: @MainActor () -> Void = {}
    #endif

    /// Decodes and validates before touching any store, so a malformed or
    /// newer-version file never changes existing settings.
    @discardableResult
    func apply(_ data: Data) throws -> Summary {
        let file = try PreferencesCoder.decode(data)
        return apply(file)
    }

    @discardableResult
    func apply(_ file: PreferencesFile) -> Summary {
        var summary = Summary()

        if let policy = file.retentionPolicy {
            library.retentionPolicy = policy
            try? library.applyRetention()
            summary.appliedRetentionPolicy = true
        }
        if let timeout = file.appLockTimeout {
            appLock.timeout = timeout
            summary.appliedAppLockTimeout = true
        }
        summary.vocabularyProjectCount = applyVocabularies(file.vocabularies)

        #if os(macOS)
        if let preference = file.automaticRecording {
            for app in automaticRecording.apps() {
                automaticRecording.setAllowed(preference.allowedBundleIDs.contains(app.bundleID), forBundleID: app.bundleID)
            }
            automaticRecording.setWatching(preference.watching)
            summary.appliedAutomaticRecording = true
        }
        if let preference = file.meetingSites {
            for site in meetingSites.sites() {
                meetingSites.setAllowed(preference.allowedHosts.contains(site.host), forHost: site.host)
            }
            meetingSites.suggestsSpeakerNames = preference.suggestsSpeakerNames
            summary.appliedMeetingSites = true
        }
        if let mediaHintOff = file.mediaHintOff {
            mediaHint.isOff = mediaHintOff
            summary.appliedMediaHint = true
        }
        if let uid = file.microphoneUID, let name = file.microphoneName {
            microphone.setChosen(ChosenMicrophone(uid: uid, name: name))
            summary.appliedMicrophone = true
        }
        if let keyCode = file.shortcutKeyCode, let modifiers = file.shortcutModifiers, let key = file.shortcutKey {
            shortcut.save(KeyCombo(keyCode: keyCode, modifiers: modifiers, key: key))
            summary.appliedShortcut = true
        }
        afterApply()
        #endif

        return summary
    }

    /// Merges into projects this device already holds, matching by id and
    /// falling back to an exact name match. A project this device does not
    /// hold is skipped rather than created, so import never grants access.
    private func applyVocabularies(_ preferences: [VocabularyPreference]) -> Int {
        var count = 0
        for preference in preferences {
            guard let project = library.project(withID: preference.projectID)
                ?? library.projects.first(where: { $0.name == preference.projectName })
            else { continue }

            let incoming = ProjectVocabulary(projectID: project.id, terms: preference.terms)
            let merged = ProjectVocabulary.merge(library.vocabulary(forProject: project.id), incoming)
            try? library.saveVocabulary(merged)
            count += 1
        }
        return count
    }
}
