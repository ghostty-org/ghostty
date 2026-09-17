import AppKit
import SwiftUI
import CodeEditSourceEditor

private struct EditorTerminalControllerKey: EnvironmentKey {
    static let defaultValue: TerminalController? = nil
}

extension EnvironmentValues {
    var editorTerminalController: TerminalController? {
        get { self[EditorTerminalControllerKey.self] }
        set { self[EditorTerminalControllerKey.self] = newValue }
    }
}

struct EditorPaneContainer<Terminal: View>: View {
    @Environment(\.editorTerminalController) private var controller
    let surfaceView: Ghostty.SurfaceView
    @ViewBuilder var terminal: () -> Terminal

    var body: some View {
        if let controller {
            EditorWorkspaceHost(controller: controller, surfaceView: surfaceView, terminal: terminal)
        } else {
            terminal()
        }
    }
}

/// The editor occupies one existing split leaf; its terminal remains alive underneath.
struct EditorWorkspaceHost<Terminal: View>: View {
    @ObservedObject private var settings = OhMyGhosttySettings.shared
    @ObservedObject var controller: TerminalController
    @ObservedObject private var workspace: EditorWorkspace
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    private let terminal: Terminal

    init(controller: TerminalController, surfaceView: Ghostty.SurfaceView, @ViewBuilder terminal: () -> Terminal) {
        self.controller = controller
        self.surfaceView = surfaceView
        self.workspace = EditorWorkspaceStore.shared.workspace(for: controller.tabSessionID, surfaceID: surfaceView.id)
        self.terminal = terminal()
    }

    var body: some View {
        ZStack {
            terminal
                .opacity(workspace.isVisible ? 0 : 1)
                .allowsHitTesting(!workspace.isVisible)
                .accessibilityHidden(workspace.isVisible)
            if !workspace.documents.isEmpty || !workspace.gitDiffs.isEmpty || workspace.isVisible {
                EditorVisibilityHost(isVisible: workspace.isVisible) {
                    editor
                        .accessibilityHidden(!workspace.isVisible)
                        .simultaneousGesture(TapGesture().onEnded {
                            if controller.focusedSurface !== surfaceView {
                                controller.focusedSurface = surfaceView
                            }
                        })
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !workspace.isVisible, !workspace.documents.isEmpty || !workspace.gitDiffs.isEmpty {
                Button("Editor") {
                    if controller.focusedSurface !== surfaceView {
                        controller.focusedSurface = surfaceView
                    }
                    workspace.isVisible = true
                }.padding(8)
            }
        }
        .onChange(of: workspace.isVisible) { visible in
            if visible {
                if controller.focusedSurface !== surfaceView {
                    controller.focusedSurface = surfaceView
                }
            } else if controller.focusedSurface === surfaceView, controller.window?.isVisible == true {
                controller.focusSurface(surfaceView)
            }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(workspace.documents, id: \.id) { document in
                                EditorDocumentTab(
                                    document: document,
                                    isSelected: workspace.selectedID == document.id,
                                    select: { workspace.selectedID = document.id },
                                    close: { close(document) }
                                )
                                .id(document.id)
                            }
                            ForEach(workspace.gitDiffs) { request in
                                HStack(spacing: 6) {
                                    Button { workspace.selectGitDiff(request) } label: {
                                        Label(request.tabTitle, systemImage: "arrow.left.arrow.right")
                                            .lineLimit(1)
                                    }
                                    Button { workspace.closeGitDiff(request) } label: {
                                        Image(systemName: "xmark").font(.caption2)
                                    }.help(GitL10n.text("Close Diff"))
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(workspace.gitDiff?.id == request.id ? Color.accentColor.opacity(0.16) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                                .help(request.repository.worktreePath + " — " + request.tabTitle)
                                .id(request.id)
                            }
                        }
                    }
                    .onChange(of: workspace.gitDiff?.id) { selected in
                        if let selected { proxy.scrollTo(selected) }
                    }
                    .onChange(of: workspace.selectedID) { selected in
                        if let selected { proxy.scrollTo(selected) }
                    }
                }
                Button(action: openFile) { Image(systemName: "folder.badge.plus") }
                    .help("Open File")
                Button { workspace.isVisible = false } label: {
                    Image(systemName: "rectangle.compress.vertical")
                }
                .help("Hide Editor")
            }
            .buttonStyle(.borderless)
            .padding(6)
            Divider()
            if let error = workspace.errorMessage {
                HStack(alignment: .top) {
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { workspace.errorMessage = nil } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(10)
                .background(Color.red.opacity(0.1))
            }
            if workspace.isLoading {
                ProgressView("Opening file…").padding(8)
            }
            ZStack {
                // Every open document keeps its native editor while another
                // document or a diff is selected, preserving undo and view state.
                if !workspace.documents.isEmpty {
                    ForEach(workspace.documents, id: \.id) { document in
                        let selected = workspace.gitDiff == nil && workspace.selectedID == document.id
                        EditorDocumentView(
                            document: document,
                            isActive: selected && workspace.isVisible,
                            isSurfaceFocused: {
                                (controller.focusedSurface ?? controller.surfaceTree.first) === surfaceView
                            },
                            terminalBackground: appearanceTheme.background,
                            terminalBackgroundOpacity: appearanceOpacity,
                            terminalTheme: appearanceTheme,
                            onFocus: {
                                if controller.focusedSurface !== surfaceView {
                                    controller.focusedSurface = surfaceView
                                }
                            },
                            save: { Task { await workspace.save(document) } },
                            close: { close(document) },
                            open: openFile,
                            nextDocument: { workspace.selectAdjacentDocument(offset: 1) },
                            previousDocument: { workspace.selectAdjacentDocument(offset: -1) },
                            saveAll: { Task { await workspace.saveAll() } },
                            onHide: { workspace.isVisible = false }
                        )
                        .opacity(selected ? 1 : 0)
                        .allowsHitTesting(selected)
                        .accessibilityHidden(!selected)
                    }
                }
                ForEach(workspace.gitDiffs) { request in
                    let selected = workspace.gitDiff?.id == request.id
                    GitEditorDiffView(request: request, theme: appearanceTheme, isActive: selected && workspace.isVisible,
                        actions: GitDiffEditorActions(
                            openFile: { file, directory in openGitFile(file, repository: request.repository, directory: directory) },
                            hide: { workspace.isVisible = false },
                            open: openFile,
                            nextDocument: { workspace.selectAdjacentDocument(offset: 1) },
                            previousDocument: { workspace.selectAdjacentDocument(offset: -1) },
                            saveAll: { Task { await workspace.saveAll() } },
                            focus: { controller.focusedSurface = surfaceView },
                            isSurfaceFocused: { (controller.focusedSurface ?? controller.surfaceTree.first) === surfaceView }
                        )) {
                        workspace.closeGitDiff(request)
                    }.id(request.id)
                        .opacity(selected ? 1 : 0)
                        .allowsHitTesting(selected)
                        .accessibilityHidden(!selected)
                }
                if workspace.gitDiffs.isEmpty && workspace.documents.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text").font(.largeTitle)
                        Text("Open a file from Files or choose Open File.")
                        Button("Open File", action: openFile)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(EditorBackdrop(color: appearanceTheme.background, opacity: appearanceOpacity, blur: appearanceBlur,
                                   usesWindowBlur: settings.editorSettings.followsOMG))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Code Editor")
    }

    private func openGitFile(_ file: GitDiffFile, repository: GitRepositoryIdentity, directory: Bool) {
        guard let session = controller.paneSessionContext(for: surfaceView) else { return }
        let context = InspectorPaneContext(tabID: controller.tabSessionID, surfaceID: surfaceView.id,
            title: session.presentationTitle, workingDirectory: repository.worktreePath,
            workspace: session.workspace, session: session)
        do { try GitFileActions.open(file, repository: repository, context: context, directory: directory) } catch { workspace.errorMessage = error.localizedDescription }
    }

    private func close(_ document: EditorDocument) {
        Task { await workspace.close(document, window: controller.window) }
    }

    private var appearanceTheme: EditorTheme {
        if settings.editorSettings.followsOMG {
            return controller.ghostty.config.editorTheme(background: NSColor(terminalColor))
        }
        if let name = settings.editorThemeName, let theme = EditorCatalogThemes.shared.theme(named: name) {
            return theme
        }
        return settings.editorSyntaxTheme.preset
    }

    private var appearanceOpacity: Double {
        settings.editorSettings.followsOMG ? terminalOpacity : settings.editorOpacity
    }

    private var appearanceBlur: OhMyGhosttyBackgroundBlur {
        guard settings.editorSettings.followsOMG else { return settings.editorBlur }
        return controller.ghostty.config.editorBackgroundBlur
    }

    private var terminalColor: Color {
        if let bg = surfaceView.backgroundColor {
            return bg
        }
        let configBg = surfaceView.derivedConfig.backgroundColor
        if configBg != Color(NSColor.windowBackgroundColor) {
            return configBg
        }
        if controller.terminalBackgroundColor != Color(NSColor.windowBackgroundColor) {
            return controller.terminalBackgroundColor
        }
        return configBg
    }

    private var terminalOpacity: Double {
        let opacity = surfaceView.derivedConfig.backgroundOpacity
        if opacity < 1.0 { return opacity }
        if controller.terminalBackgroundOpacity < 1.0 { return controller.terminalBackgroundOpacity }
        return opacity
    }

    private func openFile() {
        EditorMenuController.shared.openFile(in: controller, surface: surfaceView)
    }
}

private struct EditorDocumentTab: View {
    @ObservedObject var document: EditorDocument
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                HStack(spacing: 5) {
                    if document.isDirty { Circle().frame(width: 6, height: 6) }
                    Text((document.path as NSString).lastPathComponent).lineLimit(1)
                }
            }
            Button(action: close) { Image(systemName: "xmark").font(.caption2) }
                .help("Close File")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .help(document.filesystem.descriptor.presentationTitle + " — " + document.path)
    }
}

private struct EditorDocumentView: View {
    @ObservedObject var document: EditorDocument
    let isActive: Bool
    var isSurfaceFocused: () -> Bool = { true }
    let terminalBackground: NSColor
    let terminalBackgroundOpacity: Double
    let terminalTheme: EditorTheme
    let onFocus: () -> Void
    let save: () -> Void
    let close: () -> Void
    let open: () -> Void
    let nextDocument: () -> Void
    let previousDocument: () -> Void
    let saveAll: () -> Void
    let onHide: () -> Void

    // Each document has its own view identity in the workspace, preserving its chosen mode.
    @State private var isPreviewMode = true

    private var isMarkdownDocument: Bool {
        ["md", "markdown"].contains((document.path as NSString).pathExtension.lowercased())
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = document.saveErrorMessage {
                HStack(alignment: .top) {
                    Label("Couldn’t save: " + error, systemImage: "exclamationmark.triangle")
                        .textSelection(.enabled)
                    Spacer()
                    Button("Retry Save", action: save)
                        .disabled(document.isSaving || document.isReloading)
                }
                .font(.callout)
                .padding(10)
                .background(Color.red.opacity(0.1))
            }
            ZStack(alignment: .topLeading) {
                CodeEditorView(
                    text: $document.text,
                    fileURL: URL(fileURLWithPath: document.path),
                    isEditable: !document.isRestoringFromGit,
                    isActive: isActive,
                    isPreview: isMarkdownDocument && isPreviewMode,
                    isSurfaceFocused: isSurfaceFocused,
                    terminalBackground: terminalBackground,
                    terminalBackgroundOpacity: terminalBackgroundOpacity,
                    terminalForeground: terminalTheme.text,
                    terminalTheme: terminalTheme,
                    onFocus: onFocus,
                    onSave: save,
                    onClose: close,
                    onOpen: open,
                    onNextDocument: nextDocument,
                    onPreviousDocument: previousDocument,
                    onSaveAll: saveAll,
                    onHide: onHide
                )
                .id(document.contentGeneration)
                .opacity((isMarkdownDocument && isPreviewMode) ? 0 : 1)
                .allowsHitTesting(!(isMarkdownDocument && isPreviewMode))

                if isMarkdownDocument && isPreviewMode {
                    MarkdownPreviewView(
                        text: $document.text,
                        fileURL: URL(fileURLWithPath: document.path),
                        isRemote: document.filesystem.descriptor.kind == .ssh,
                        filesystem: document.filesystem,
                        terminalBackground: terminalBackground,
                        foregroundColor: terminalTheme.text,
                        isActive: isActive,
                        onFocus: onFocus,
                        onSave: save,
                        onSaveAll: saveAll,
                        onHide: onHide
                    )
                    .id(document.contentGeneration)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Text(document.path).lineLimit(1).truncationMode(.middle)
                    .help(document.path)
                if document.filesystem.descriptor.kind == .ssh {
                    Label(document.filesystem.descriptor.displayName, systemImage: "network")
                }
                Spacer(minLength: 8)

                if isMarkdownDocument {
                    Picker("", selection: $isPreviewMode) {
                        Text("Edit").tag(false)
                        Text("Preview").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 120)
                }

                if document.isSaving {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if document.isDirty {
                    Text("Edited")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .onChange(of: isActive) { active in
            if !active {
                document.flushAutoSave()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            document.flushAutoSave()
        }
    }

}

/// Uses the same glass implementation as the terminal. A single backdrop avoids
/// multiplying opacity between the gutter, scroll view and surrounding controls.
struct EditorBackdrop: NSViewRepresentable {
    @Environment(\.controlActiveState) private var activeState
    let color: NSColor
    let opacity: Double
    let blur: OhMyGhosttyBackgroundBlur
    var usesWindowBlur = false

    var localEffect: OhMyGhosttyBackgroundBlur {
        // Ordinary Ghostty blur is already applied behind the whole window.
        // A second NSVisualEffectView would introduce its own gray material.
        usesWindowBlur && blur == .enabled ? .disabled : blur
    }

    func makeNSView(context: Context) -> BackdropView { BackdropView() }

    func updateNSView(_ view: BackdropView, context: Context) {
        let blur = localEffect
        if context.coordinator.blur != blur {
            view.subviews.forEach { $0.removeFromSuperview() }
            context.coordinator.blur = blur
            let effect: NSView?
#if compiler(>=6.2)
            if #available(macOS 26.0, *), blur == .macosGlassRegular || blur == .macosGlassClear {
                effect = TerminalGlassView(topOffset: 0)
            } else {
                effect = blur == .disabled ? nil : NSVisualEffectView()
            }
#else
            effect = blur == .disabled ? nil : NSVisualEffectView()
#endif
            if let effect {
                effect.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(effect)
                NSLayoutConstraint.activate([
                    effect.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    effect.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    effect.topAnchor.constraint(equalTo: view.topAnchor),
                    effect.bottomAnchor.constraint(equalTo: view.bottomAnchor)
                ])
            }
        }
        view.fillColor = blur == .disabled ? color.withAlphaComponent(opacity) : .clear
#if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = view.subviews.first as? TerminalGlassView {
            glass.configure(style: blur == .macosGlassClear ? .clear : .regular,
                            backgroundColor: color, backgroundOpacity: opacity, cornerRadius: 0,
                            isKeyWindow: activeState != .inactive)
        }
#endif
        if let effect = view.subviews.first as? NSVisualEffectView {
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            effect.wantsLayer = true
            effect.layer?.backgroundColor = color.withAlphaComponent(opacity).cgColor
        }
    }

    final class BackdropView: NSView {
        // AppKit can invalidate beyond an un-clipped view's bounds. Painting
        // dirtyRect into a shared backing store tinted neighbouring terminal
        // panes after split resizing/reordering. Own and clip the background.
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            clipsToBounds = true
            layer?.masksToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        var fillColor: NSColor = .clear {
            didSet { layer?.backgroundColor = fillColor.cgColor }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var blur: OhMyGhosttyBackgroundBlur?
    }
}

/// Keeps the hidden editor's native hierarchy mounted (undo stacks, scroll
/// positions and the markdown WebView survive hide/show) while marking its
/// root NSView hidden. Opacity-only hiding left the views "visible" to
/// AppKit, so WebKit kept foreground assertions and occlusion churn running
/// and terminal scrolling stuttered. Same host model as `InspectorPaneDeck`.
struct EditorVisibilityHost<Content: View>: NSViewControllerRepresentable {
    let isVisible: Bool
    let content: Content

    init(isVisible: Bool, @ViewBuilder content: () -> Content) {
        self.isVisible = isVisible
        self.content = content()
    }

    final class Host: NSHostingController<Content> {
        // The host owns its children exclusively; size them with the
        // surrounding SwiftUI layout instead of AppKit constraints.
        // NSHostingController re-enables self-sizing when the view enters a
        // window (see unit test), so reassert after every layout pass.
        override func viewDidLayout() {
            super.viewDidLayout()
            if #available(macOS 13.0, *), !sizingOptions.isEmpty {
                sizingOptions = []
            }
        }
    }

    static func apply(isVisible: Bool, to host: Host) {
        host.view.isHidden = !isVisible
    }

    func makeNSViewController(context: Context) -> Host {
        let host = Host(rootView: content)
        Self.apply(isVisible: isVisible, to: host)
        return host
    }

    func updateNSViewController(_ host: Host, context: Context) {
        host.rootView = content
        Self.apply(isVisible: isVisible, to: host)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController host: Host, context: Context) -> CGSize? {
        if #available(macOS 13.0, *) {
            return host.sizeThatFits(in: CGSize(
                width: proposal.width ?? NSView.noIntrinsicMetric,
                height: proposal.height ?? NSView.noIntrinsicMetric
            ))
        }
        return nil
    }
}
