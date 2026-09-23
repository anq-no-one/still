import AVFoundation
import Foundation
#if os(macOS)
import AppKit
import CoreGraphics
#else
import UIKit
#endif

@MainActor
final class SystemSetupPermissions: SetupPermissions {
    private var askedForSystemAudio = false

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
