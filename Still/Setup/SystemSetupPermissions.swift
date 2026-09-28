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

    #if os(macOS)
    nonisolated static func relaunch(
        launcher: @Sendable (Process) throws -> Void = { try $0.run() },
        terminator: @Sendable () -> Void = { Task { @MainActor in NSApp.terminate(nil) } }
    ) {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", relaunchCommand(
            processID: ProcessInfo.processInfo.processIdentifier,
            bundlePath: Bundle.main.bundleURL.path(percentEncoded: false)
        )]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        _ = try? launcher(helper)
        terminator()
    }
    #else
    nonisolated static func relaunch() {}
    #endif

    nonisolated static func relaunchCommand(processID: Int32, bundlePath: String) -> String {
        let escaped = bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        return "i=0; while kill -0 \(processID) 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done; /usr/bin/open '\(escaped)'"
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
