import AVFoundation
import EventKit
import Foundation
#if os(macOS)
import AppKit
import CoreGraphics
#else
import UIKit
#endif

@MainActor
final class SystemSetupPermissions: SetupPermissions {
    private static let askedForSystemAudioKey = "still.setup.askedForSystemAudio"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var askedForSystemAudio: Bool {
        get { defaults.bool(forKey: Self.askedForSystemAudioKey) }
        set { defaults.set(newValue, forKey: Self.askedForSystemAudioKey) }
    }

    var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    var systemAudio: PermissionState {
        #if os(macOS)
        if CGPreflightScreenCaptureAccess() { return .granted }
        return askedForSystemAudio ? .denied : .notAsked
        #else
        .granted
        #endif
    }

    var calendar: PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    func requestCalendar() async {
        if calendar == .notAsked {
            _ = try? await EKEventStore().requestFullAccessToEvents()
        } else {
            Self.openSettings(anchor: "Privacy_Calendars")
        }
    }

    func requestMicrophone() async {
        if microphone == .notAsked {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            Self.openSettings(anchor: "Privacy_Microphone")
        }
    }

    func requestSystemAudio() {
        #if os(macOS)
        if askedForSystemAudio || !CGRequestScreenCaptureAccess() {
            Self.openSettings(anchor: "Privacy_ScreenCapture")
        }
        askedForSystemAudio = true
        #endif
    }

    static func relaunch() {
        #if os(macOS)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
        #endif
    }

    static func openPasscodeSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.password") {
            NSWorkspace.shared.open(url)
        }
        #else
        openSettings(anchor: "")
        #endif
    }

    private static func openSettings(anchor: String) {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}
