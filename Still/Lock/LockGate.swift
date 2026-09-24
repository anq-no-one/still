import SwiftUI

struct LockGate<Content: View>: View {
    let lock: AppLock
    let coordinator: RecordingCoordinator
    @ViewBuilder let content: () -> Content

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if lock.isLocked {
                LockedView(lock: lock, coordinator: coordinator)
            } else {
                content()
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                lock.didReturn()
            } else if Self.leaves(in: phase) {
                lock.didLeave()
            }
        }
    }

    private static func leaves(in phase: ScenePhase) -> Bool {
        #if os(macOS)
        phase != .active
        #else
        phase == .background
        #endif
    }
}

private struct LockedView: View {
    let lock: AppLock
    let coordinator: RecordingCoordinator

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Still Is Locked")
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)

            if coordinator.isRecording {
                RecordingWhileLocked(coordinator: coordinator)
            }

            problemText

            VStack(spacing: 12) {
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Text("Unlock")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(lock.isAuthenticating)

                if case .unavailable = lock.problem {
                    Button("Open Settings", action: SystemSetupPermissions.openPasscodeSettings)
                        .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: 320)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await lock.unlock()
        }
    }

    @ViewBuilder
    private var problemText: some View {
        switch lock.problem {
        case .failed(let message), .unavailable(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        case .cancelled:
            Text("Your recordings stay hidden until you unlock Still.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .success, nil:
            EmptyView()
        }
    }
}

private struct RecordingWhileLocked: View {
    let coordinator: RecordingCoordinator

    var body: some View {
        VStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Label {
                    Text("Recording · \(coordinator.elapsed.recordingDurationText)")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                }
            }

            Button("Stop and Save", systemImage: "stop.fill") {
                Task { await coordinator.stopAndSave() }
            }
            .buttonStyle(.bordered)
            .disabled(!coordinator.canStop)
        }
        .padding()
        .background(.quaternary, in: .rect(cornerRadius: 12))
    }
}
