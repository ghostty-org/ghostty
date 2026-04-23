import SwiftUI
import GhosttiesMCPClient

/// Settings pane for managing external MCP sources (Linear, Sentry, GitHub...).
///
/// Lists currently-configured sources with a status dot, exposes "Add MCP
/// Source" that opens a sheet, and allows per-row delete. Non-secret config is
/// written to `.ghostties/mcp-sources.json`; API keys go to the Keychain.
@MainActor
struct MCPSourceSettingsView: View {
    @StateObject private var store = MCPSourceSettingsStore()
    @State private var showAddSheet = false
    @State private var editingSource: MCPSource?
    @State private var pendingDelete: MCPSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if let loadError = store.loadError {
                errorBanner(loadError)
            }

            if store.sources.isEmpty {
                emptyState
            } else {
                sourceList
            }

            Divider()

            footer
        }
        .frame(minWidth: 520, idealWidth: 560, maxWidth: .infinity,
               minHeight: 400, idealHeight: 440, maxHeight: .infinity)
        .sheet(isPresented: $showAddSheet) {
            AddMCPSourceSheet(
                store: store,
                existing: nil,
                onClose: { showAddSheet = false }
            )
        }
        .sheet(item: $editingSource) { source in
            AddMCPSourceSheet(
                store: store,
                existing: source,
                onClose: { editingSource = nil }
            )
        }
        .confirmationDialog(
            pendingDelete.map { "Remove \"\($0.name)\"?" } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { source in
            Button("Remove", role: .destructive) {
                delete(source)
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("This removes the configuration and any stored API key from your Keychain. You can re-add the source later.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MCP Sources")
                .font(.system(size: 16, weight: .semibold))
            Text("Connect external services — Linear, Sentry, GitHub Issues — so their tickets appear in your Inbox lane.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No MCP sources yet")
                .font(.system(size: 13, weight: .medium))
            Text("Add a source to pull real tickets into your sidebar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var sourceList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(store.sources) { source in
                    MCPSourceRow(
                        source: source,
                        status: store.status(for: source.id),
                        onEdit: { editingSource = source },
                        onDelete: { pendingDelete = source }
                    )
                    Divider()
                        .padding(.leading, 20)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Add MCP Source…") {
                showAddSheet = true
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Couldn't load mcp-sources.json: \(message)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - Actions

    private func delete(_ source: MCPSource) {
        do {
            try store.delete(id: source.id)
        } catch {
            // Surface via loadError banner — reload() will set it if save fails.
            store.reload()
        }
        pendingDelete = nil
    }
}

// MARK: - Row

@MainActor
private struct MCPSourceRow: View {
    let source: MCPSource
    let status: MCPSourceSettingsStore.SourceStatus
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            statusDot

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if isHovering {
                Button("Edit", action: onEdit)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove source")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .help(dotHelp)
    }

    private var dotColor: Color {
        switch status {
        case .untested: return Color.secondary.opacity(0.5)
        case .connected: return .green
        case .error: return .red
        }
    }

    private var dotHelp: String {
        switch status {
        case .untested: return "Not tested yet"
        case .connected: return "Connected"
        case .error(let reason): return "Error: \(reason)"
        }
    }

    private var subtitle: String {
        var parts: [String] = [source.transport.rawValue]
        parts.append(source.endpoint)
        if let args = source.args, !args.isEmpty {
            parts.append(args.joined(separator: " "))
        }
        return parts.joined(separator: "  ·  ")
    }
}
