import AppKit
import SwiftUI

@MainActor
final class SSHSessionManagerController: NSWindowController, NSWindowDelegate {
    static let shared = SSHSessionManagerController()
    private let store = SSHSessionStore()
    private var ghostty: Ghostty.App?
    private var editingMonitor: Any?
    private var presenting = false
    private var pendingLaunch: (() -> Void)?
    private weak var connectionParent: NSWindow?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1302, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "SSH Connections"
        window.minSize = NSSize(width: 1080, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.isRestorable = false
        window.contentView = NSHostingView(rootView: SSHSessionManager(store: store, dismiss: { [weak self] in
            self?.dismissModal()
        }) { [weak self] profile, newWindow in
            self?.connect(profile, newWindow: newWindow)
        })
        window.center()
        editingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let root = self?.window, SSHTextEditing.belongs(event.window ?? NSApp.keyWindow, to: root),
                  SSHTextEditing.handle(event, in: event.window ?? NSApp.keyWindow) else { return event }
            return nil
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ ghostty: Ghostty.App) {
        guard let window else { return }
        if presenting {
            window.makeKeyAndOrderFront(nil)
            return
        }
        self.ghostty = ghostty
        connectionParent = TerminalController.preferredParent?.window
        presenting = true
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        presenting = false
        connectionParent = nil
        let launch = pendingLaunch
        pendingLaunch = nil
        launch?()
    }

    func windowWillClose(_ notification: Notification) {
        dismissModal()
    }

    private func dismissModal() {
        if let window, NSApp.modalWindow === window { NSApp.stopModal() }
        window?.orderOut(nil)
    }

    private func connect(_ profile: SSHProfile, newWindow: Bool) {
        guard let ghostty else { return }
        do {
            guard Bundle.main.executableURL != nil else { throw SSHError.message("Ghostty executable could not be located.") }
            let specification = try SSHRuntime.prepare(profile)
            let parent = connectionParent ?? TerminalController.preferredParent?.window
            pendingLaunch = { [weak self] in
                guard let self else { SSHRuntime.discard(specification); return }
                self.openConnection(ghostty, specification: specification, newWindow: newWindow, parent: parent)
            }
            dismissModal()
        } catch { store.error = error.localizedDescription }
    }

    private func openConnection(_ ghostty: Ghostty.App, specification: URL, newWindow: Bool, parent: NSWindow?) {
        guard let executable = Bundle.main.executableURL else { SSHRuntime.discard(specification); return }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "\(SSHInvocation.shellQuote(executable.path)) --ghostty-ssh-launch \(SSHInvocation.shellQuote(specification.path))"
        config.waitAfterCommand = true
        let controller: TerminalController
        if !newWindow, let parent,
           let tab = TerminalController.newTab(ghostty, from: parent, withBaseConfig: config) {
            controller = tab
        } else {
            controller = TerminalController.newWindow(ghostty, withBaseConfig: config)
        }
        controller.window?.makeKeyAndOrderFront(nil)
        if controller.surfaceTree.root == nil { SSHRuntime.discard(specification) }
    }

}

private struct SSHSessionManager: View {
    @ObservedObject var store: SSHSessionStore
    var dismiss: () -> Void
    var connect: (SSHProfile, Bool) -> Void
    @State private var search = ""
    @State private var filter = "all"
    @State private var selection: UUID?
    @State private var editing: SSHProfile?
    @State private var deleting: SSHProfile?
    @State private var addingFolder = false
    @State private var folderName = ""

    private var profiles: [SSHProfile] {
        store.document.profiles.filter { profile in
            let matchesFolder = filter == "all" || (filter == "favorites" && profile.favorite) || profile.folderID?.uuidString == filter
            let matchesSearch = search.isEmpty || [profile.name, profile.destination, profile.username]
                .contains { $0.localizedCaseInsensitiveContains(search) }
            return matchesFolder && matchesSearch
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var selected: SSHProfile? { profiles.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                List(selection: $filter) {
                    Label("All Connections", systemImage: "network").tag("all")
                    Label("Favorites", systemImage: "star").tag("favorites")
                    Section("Folders") {
                        ForEach(store.document.folders) { folder in
                            Label(folder.name, systemImage: "folder").tag(folder.id.uuidString)
                                .contextMenu {
                                    Button("Remove Folder") { perform { try store.deleteFolder(folder.id); filter = "all" } }
                                }
                        }
                    }
                }.frame(minWidth: 150, idealWidth: 180, maxWidth: 240)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Search connections", text: $search).textFieldStyle(.roundedBorder).padding([.top, .horizontal], 10)
                    List(selection: $selection) {
                        ForEach(profiles) { profile in
                            HStack {
                                Image(systemName: profile.favorite ? "star.fill" : "server.rack").foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name).fontWeight(.medium).lineLimit(1)
                                    HStack(spacing: 12) {
                                        Label(profile.username.isEmpty ? "From SSH config" : profile.username, systemImage: "person")
                                            .fixedSize(horizontal: true, vertical: false)
                                        Label(profile.destination, systemImage: "network").lineLimit(1)
                                    }.font(.caption).foregroundColor(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(profile.authentication.title)
                                    Text(profile.terminalType.title + " · " + profile.encoding.rawValue)
                                }.font(.caption).foregroundColor(.secondary).lineLimit(1).frame(maxWidth: 220, alignment: .trailing)
                            }
                            .padding(.vertical, 3).contentShape(Rectangle()).tag(profile.id)
                            .onTapGesture(count: 2) { connect(profile, false) }
                            .contextMenu {
                                Button("Connect in New Tab") { connect(profile, false) }
                                Button("Connect in New Window") { connect(profile, true) }
                                Divider()
                                Button("Edit…") { editing = profile }
                                Button("Duplicate") { duplicate(profile) }
                                Button(profile.favorite ? "Remove Favorite" : "Add Favorite") { perform { try store.toggleFavorite(profile) } }
                                Button("Delete…") { deleting = profile }
                            }
                        }
                    }
                    .overlay {
                        if profiles.isEmpty { Text("No connections. Add one to get started.").foregroundColor(.secondary).allowsHitTesting(false) }
                    }
                    .onExitCommand { dismiss() }
                }.frame(minWidth: 450)
            }
            Divider()
            HStack {
                Menu {
                    Button("New Connection…") { editing = SSHProfile() }
                    Button("New Folder…") { addingFolder = true }
                } label: { Label("Add", systemImage: "plus") }.fixedSize()
                Button("Edit…") { editing = selected }.disabled(selected == nil)
                Button("Reload") { store.reload() }
                Spacer()
                Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
                Button("New Window") { if let selected { connect(selected, true) } }.disabled(selected == nil)
                Button("Connect") { if let selected { connect(selected, false) } }
                    .keyboardShortcut(.defaultAction).disabled(selected == nil)
            }.padding(10)
        }
        .sheet(item: $editing) { profile in SSHSessionEditor(store: store, profile: profile) }
        .alert("SSH Connections", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("Delete connection?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let deleting { perform { try store.delete(deleting) } }
                deleting = nil
            }
        } message: { Text("The connection and its saved credentials will be removed. Active sessions will stay open.") }
        .sheet(isPresented: $addingFolder) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New Folder").font(.headline)
                TextField("Name", text: $folderName)
                HStack {
                    Spacer()
                    Button("Cancel") { addingFolder = false }.keyboardShortcut(.cancelAction)
                    Button("Create") {
                        perform { try store.addFolder(folderName); folderName = ""; addingFolder = false }
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 320)
        }
    }

    private func duplicate(_ profile: SSHProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name += " Copy"
        copy.passwordID = nil
        copy.passphraseID = nil
        editing = copy
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { store.error = error.localizedDescription }
    }
}
