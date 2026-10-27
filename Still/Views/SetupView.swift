import SwiftUI

struct SetupView: View {
    let flow: SetupFlow
    let models: ModelInstallers

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 56

    private var installer: ModelPackInstaller {
        models.transcription
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                currentStep
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .stillSheetWidth(mac: 440, minHeight: 520)
        .animation(reduceMotion ? nil : .default, value: flow.step)
        .task {
            await models.resumeIfApproved()
        }
        .task {
            while !Task.isCancelled {
                flow.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var currentStep: some View {
        Group {
            switch flow.step {
            case .privacy:
                privacyStep
            case .microphone:
                microphoneStep
            case .systemAudio:
                systemAudioStep
            case .calendar:
                calendarStep
            case .callNames:
                callNamesStep
            case .transcription:
                transcriptionStep
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
    }

    private var privacyStep: some View {
        step(
            icon: "lock.shield.fill",
            title: "Your Recordings Stay Here",
            body: "Still records, transcribes, and stores everything on this device. There is no account, and nothing is sent anywhere until you ask for it. The next steps explain each permission before your device asks for it."
        ) {
            primary("Continue", action: flow.acknowledgePrivacy)
        }
    }

    private var microphoneStep: some View {
        step(
            icon: "mic.fill",
            title: "Let Still Hear You",
            body: flow.microphone == .denied
                ? Self.microphoneDeniedText
                : String(localized: "Still needs the microphone to record you. Everything it hears stays on this device.")
        ) {
            primary(flow.microphone == .denied ? "Open Settings" : "Allow Microphone") {
                Task { await flow.requestMicrophone() }
            }
        }
    }

    private static var microphoneDeniedText: String {
        #if os(macOS)
        String(localized: "Still cannot record without the microphone. Turn on Still in Privacy & Security → Microphone, then come back.")
        #else
        String(localized: "Still cannot record without the microphone. Turn on Microphone for Still in Settings, then come back.")
        #endif
    }

    private var systemAudioStep: some View {
        step(
            icon: "person.2.wave.2.fill",
            title: "Hear Everyone on the Call",
            body: flow.systemAudio == .denied
                ? String(localized: "Turn on Still in Privacy & Security → Screen & System Audio Recording. Still records only sound, never your screen.")
                : String(localized: "To record the other people on a call, macOS asks you to allow Screen & System Audio Recording. Still records only sound, never your screen.")
        ) {
            primary(flow.systemAudio == .denied ? "Open System Settings" : "Allow", action: flow.requestSystemAudio)
            if flow.systemAudio == .denied {
                secondary("I Allowed It — Reopen Still", action: { SystemSetupPermissions.relaunch() })
            }
        }
    }

    private var calendarStep: some View {
        step(
            icon: "calendar",
            title: "Know Who Is in the Meeting",
            body: String(localized: "Still can read the event you are in to put names on the people speaking in your recordings. The calendar stays on this device. This is optional: without it, you name speakers yourself, and you can turn it on later in Settings.")
        ) {
            primary("Allow Calendar") {
                Task { await flow.requestCalendar() }
            }
            secondary("Not Now", action: flow.skipCalendar)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var callNamesStep: some View {
        step(
            icon: "person.wave.2.fill",
            title: "Name the People Speaking on Calls",
            body: String(localized: "During a Microsoft Teams call, Still can read who Teams marks as speaking, so each line of the transcript carries the right name. macOS calls this Accessibility access. Still reads only the Teams meeting window and keeps the names on this device. This is optional, and you can turn it on later in Settings.")
        ) {
            primary("Allow", action: flow.requestCallNames)
            secondary("Not Now", action: flow.skipCallNames)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var transcriptionStep: some View {
        step(
            icon: "waveform",
            title: "Transcribe on This Device",
            body: installer.pack.purpose
        ) {
            switch installer.state {
            case .installing, .verifying:
                ProgressView(value: installer.progress) {
                    Text("Downloading…")
                } currentValueLabel: {
                    Text(installer.progress, format: .percent.precision(.fractionLength(0)))
                }
                .accessibilityValue(Text(installer.progress, format: .percent.precision(.fractionLength(0))))
            case .failed:
                primary("Try Again") {
                    Task { await models.approveAndInstall() }
                }
            default:
                primary("Download \(models.downloadSizeText)") {
                    Task { await models.approveAndInstall() }
                }
            }
        }
    }

    private func step<Actions: View>(
        icon: String,
        title: LocalizedStringKey,
        body text: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 20) {
            if let number = flow.stepNumber {
                Text("Step \(number) of \(flow.stepCount)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.75))
            }

            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(minHeight: iconSize + 16)
                .accessibilityHidden(true)

            Text(title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(text)
                .font(.body)
                .foregroundStyle(.primary.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if case .failed(let message) = installer.state, flow.step == .transcription {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                actions()
            }
            .frame(maxWidth: 360)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }

    private func primary(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    private func secondary(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
    }
}
