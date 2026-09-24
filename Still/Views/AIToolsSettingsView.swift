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

                Section("Connected") {
                    if access.clients.isEmpty {
                        Text("No AI tool is connected.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(access.clients) { client in
                        LabeledContent {
                            Button("Revoke", role: .destructive) { access.revoke(client) }
                        } label: {
                            Text(client.version.map { "\(client.name) \($0)" } ?? client.name)
                            Text(client.connectedAt, format: .dateTime.hour().minute())
                        }
                    }
                }

                if !access.blockedClients.isEmpty {
                    Section("Revoked") {
                        ForEach(access.blockedClients, id: \.self) { name in
                            LabeledContent(name) {
                                Button("Allow") { access.allow(name) }
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
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
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
