import Foundation

/// Everything a device is willing to hand another device: project vocabulary,
/// the recording shortcut, and ordinary preferences. Keys, recovery material,
/// consents, project availability, and local-tool approvals never enter this
/// type, so they cannot leak into an exported file by accident.
struct PreferencesFile: Codable, Equatable, Sendable {
    static let kind = "still.preferences"
    static let currentVersion = 1

    var kind: String
    var version: Int
    var exportedAt: Date
    var retentionPolicy: RetentionPolicy?
    var appLockTimeout: TimeInterval?
    var vocabularies: [VocabularyPreference]
    var automaticRecording: AutomaticRecordingPreference?
    var meetingSites: MeetingSitesPreference?
    var mediaHintOff: Bool?
    var microphoneUID: String?
    var microphoneName: String?
    var shortcutKeyCode: UInt32?
    var shortcutModifiers: UInt32?
    var shortcutKey: String?

    init(
        exportedAt: Date = .now,
        retentionPolicy: RetentionPolicy? = nil,
        appLockTimeout: TimeInterval? = nil,
        vocabularies: [VocabularyPreference] = [],
        automaticRecording: AutomaticRecordingPreference? = nil,
        meetingSites: MeetingSitesPreference? = nil,
        mediaHintOff: Bool? = nil,
        microphoneUID: String? = nil,
        microphoneName: String? = nil,
        shortcutKeyCode: UInt32? = nil,
        shortcutModifiers: UInt32? = nil,
        shortcutKey: String? = nil
    ) {
        kind = Self.kind
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.retentionPolicy = retentionPolicy
        self.appLockTimeout = appLockTimeout
        self.vocabularies = vocabularies
        self.automaticRecording = automaticRecording
        self.meetingSites = meetingSites
        self.mediaHintOff = mediaHintOff
        self.microphoneUID = microphoneUID
        self.microphoneName = microphoneName
        self.shortcutKeyCode = shortcutKeyCode
        self.shortcutModifiers = shortcutModifiers
        self.shortcutKey = shortcutKey
    }
}

/// Keyed by both id and name so a device that never saw this project's id
/// can still match it by its exact name.
struct VocabularyPreference: Codable, Equatable, Sendable {
    let projectID: UUID
    let projectName: String
    let terms: [VocabularyTerm]
}

struct AutomaticRecordingPreference: Codable, Equatable, Sendable {
    let allowedBundleIDs: [String]
    let watching: Bool
}

struct MeetingSitesPreference: Codable, Equatable, Sendable {
    let allowedHosts: [String]
    let suggestsSpeakerNames: Bool
}

enum PreferencesImportError: Error, Equatable, LocalizedError {
    case malformed
    case unsupportedKind
    case newerVersion(Int)

    var errorDescription: String? {
        switch self {
        case .malformed, .unsupportedKind:
            String(localized: "This file isn't a Still settings export.")
        case .newerVersion:
            String(localized: "This settings file was made by a newer version of Still. Update Still and try again.")
        }
    }
}

enum PreferencesCoder {
    static func encode(_ file: PreferencesFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    static func decode(_ data: Data) throws -> PreferencesFile {
        let file: PreferencesFile
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            file = try decoder.decode(PreferencesFile.self, from: data)
        } catch {
            throw PreferencesImportError.malformed
        }
        try validate(file)
        return file
    }

    static func validate(_ file: PreferencesFile) throws {
        guard file.kind == PreferencesFile.kind else { throw PreferencesImportError.unsupportedKind }
        guard file.version <= PreferencesFile.currentVersion else { throw PreferencesImportError.newerVersion(file.version) }
    }
}

#if os(macOS)
protocol MediaHintPreferencesStore: Sendable {
    var isOff: Bool { get nonmutating set }
}

struct UserDefaultsMediaHintPreferencesStore: MediaHintPreferencesStore, @unchecked Sendable {
    private let key = "still.mediaHint.off"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isOff: Bool {
        get { defaults.bool(forKey: key) }
        nonmutating set { defaults.set(newValue, forKey: key) }
    }
}
#endif
