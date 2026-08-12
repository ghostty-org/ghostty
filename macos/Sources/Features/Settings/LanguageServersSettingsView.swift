import SwiftUI

/// Per-server configuration: which binary, what arguments, and raw
/// `initializationOptions` JSON — the knobs `LSPServerRegistry` used to be
/// the only word on.
///
/// One row per distinct binary (`LSPServerRegistry.distinctServers`)
/// rather than per language id: four of the ids in the registry are the
/// same TypeScript process, and a user who points that at a different
/// binary means all four, not one quarter of them.
///
/// Live per-file server status already lives in the editor's own banner,
/// scoped to the workspace that's actually open — a language can be
/// running in one window's root and crashed in another's, so a global
/// status row here would just be misleading. This view is only the
/// configuration half.
struct LanguageServersSettingsView: View {
    @State private var selection: LSPServerDefinition?

    var body: some View {
        NavigationSplitView {
            List(LSPServerRegistry.distinctServers, selection: $selection) { server in
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.displayName)
                    Text(languageIDs(sharing: server.command))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(server)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let selection {
                LanguageServerOverrideForm(server: selection)
                    .id(selection.id)
            } else {
                Text("Select a language server.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 360)
    }

    private func languageIDs(sharing command: String) -> String {
        LSPServerRegistry.all.filter { $0.command == command }.map(\.languageID).joined(separator: ", ")
    }
}

/// One server's editable override, backed by `LSPServerOverrideStore`.
///
/// Split out from the list above so `.id(selection.id)` there forces a
/// fresh `@State` per server — without it, switching the sidebar selection
/// would keep editing the previous server's override in place, since
/// SwiftUI would otherwise reuse the same view identity and its state.
private struct LanguageServerOverrideForm: View {
    let server: LSPServerDefinition
    @State private var override: LSPServerOverride

    init(server: LSPServerDefinition) {
        self.server = server
        _override = State(initialValue: LSPServerOverrideStore.override(for: server.command) ?? LSPServerOverride())
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Default Command") {
                    Text(server.invocation)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Install") {
                    Text(server.installHint)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                TextField("Command", text: $override.command, prompt: Text(server.command))
                TextField(
                    "Arguments",
                    text: $override.arguments,
                    prompt: Text(server.arguments.joined(separator: " "))
                )
            } header: {
                Text("Override")
            } footer: {
                Text(
                    """
                    Blank uses the default above. Takes effect the next \
                    time this server starts for a workspace — close and \
                    reopen a file of this kind, or relaunch Phantom.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $override.initializationOptionsJSON)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120)
            } header: {
                Text("initializationOptions (JSON)")
            } footer: {
                Text(
                    """
                    Sent to the server at startup. Left blank, Phantom's \
                    own resolution is used where it has one — Vue's \
                    TypeScript path today; every other server gets none.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(server.displayName)
        .onChange(of: override) { value in
            LSPServerOverrideStore.set(value, for: server.command)
        }
    }
}
