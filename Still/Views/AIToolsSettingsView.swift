#if os(macOS)
import AppKit
import SwiftUI

struct AIToolsSettingsView: View {
    let access: MCPAccess
    let library: Library

    var body: some View {
        Form {
            Section {
                Toggle("Allow AI tools to read meetings", isOn: enabled)
            } footer: {
                Text("AI tools on this Mac, such as Claude Code and Codex, can read your meetings, transcripts and notes while Still is open and your Library is unlocked. They connect through Still itself, never over the internet.")
            }

            if access.isEnabled {
                if library.state != .unlocked {
                    Label("Your Library is locked, so AI tools get an error until you unlock it.", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                }
                if let failure = access.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                Section("Connect") {
                    snippet("Claude Code", MCPClientConfig.claudeCode(helperPath: helperPath))
                    snippet("Codex (~/.codex/config.toml)", MCPClientConfig.codex(helperPath: helperPath))
                }

                if !access.waitingClients.isEmpty {
                    Section {
                        ForEach(access.waitingClients, id: \.self) { name in
                            LabeledContent(name) {
                                Button("Approve") { access.approve(name) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    } header: {
                        Text("Waiting for Approval")
                    } footer: {
                        Text("A tool reads nothing until you approve it here. After approval it can read transcripts, confirmed and extracted facts, decisions, and accepted tasks from the projects on this Mac, never audio, and it cannot change anything.")
                    }
                }

                Section("Approved") {
                    if access.approvedClients.isEmpty {
                        Text("No AI tool is approved.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(access.approvedClients, id: \.self) { name in
                        LabeledContent {
                            Button("Revoke", role: .destructive) { access.revoke(name) }
                        } label: {
                            Text(name)
                            if let client = access.clients.first(where: { $0.name == name }) {
                                Text("Connected since \(client.connectedAt.formatted(.dateTime.hour().minute()))")
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .settingsPaneTitle("AI Tools")
    }

    private var helperPath: String {
        access.helperURL.path(percentEncoded: false)
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { access.isEnabled },
            set: { $0 ? access.enable() : access.disable() }
        )
    }

    private func snippet(_ title: LocalizedStringKey, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("Copy") {
                    NoteClipboard.copy(text)
                }
            }
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
