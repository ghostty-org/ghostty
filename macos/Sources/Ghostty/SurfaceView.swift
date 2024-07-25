import SwiftUI
import UserNotifications
import GhosttyKit

extension Ghostty {
    /// Render a terminal for the active app in the environment.
    struct Terminal: View {
        @EnvironmentObject private var ghostty: Ghostty.App
        @FocusedValue(\.ghosttySurfaceTitle) private var surfaceTitle: String?

        var body: some View {
            if let app = self.ghostty.app {
                SurfaceForApp(app) { surfaceView in
                    SurfaceWrapper(surfaceView: surfaceView)
                }
                .navigationTitle(surfaceTitle ?? "Ghostty")
            }
        }
    }

    /// Yields a SurfaceView for a ghostty app that can then be used however you want.
    struct SurfaceForApp<Content: View>: View {
        let content: ((SurfaceView) -> Content)

        @StateObject private var surfaceView: SurfaceView

        init(_ app: ghostty_app_t, @ViewBuilder content: @escaping ((SurfaceView) -> Content)) {
            _surfaceView = StateObject(wrappedValue: SurfaceView(app))
            self.content = content
        }

        var body: some View {
            content(surfaceView)
        }
    }
    
    struct SurfaceWrapper: View {
        // The surface to create a view for. This must be created upstream. As long as this
        // remains the same, the surface that is being rendered remains the same.
        @ObservedObject var surfaceView: SurfaceView

        // True if this surface is part of a split view. This is important to know so
        // we know whether to dim the surface out of focus.
        var isSplit: Bool = false
        
        // Maintain whether our view has focus or not
        @FocusState private var surfaceFocus: Bool

        // Maintain whether our window has focus (is key) or not
        @State private var windowFocus: Bool = true
        
        // True if we're hovering over the left URL view, so we can show it on the right.
        @State private var isHoveringURLLeft: Bool = false
        
        @EnvironmentObject private var ghostty: Ghostty.App
        
        var body: some View {
            let center = NotificationCenter.default
            
            ZStack {
                // We use a GeometryReader to get the frame bounds so that our metal surface
                // is up to date. See TerminalSurfaceView for why we don't use the NSView
                // resize callback.
                GeometryReader { geo in
                    // We use these notifications to determine when the window our surface is
                    // attached to is or is not focused.
                    let pubBecomeFocused = center.publisher(for: Notification.didBecomeFocusedSurface, object: surfaceView)
                    
                    #if canImport(AppKit)
                    let pubBecomeKey = center.publisher(for: NSWindow.didBecomeKeyNotification)
                    let pubResign = center.publisher(for: NSWindow.didResignKeyNotification)
                    #endif

                    Surface(view: surfaceView, size: geo.size)
                        .focused($surfaceFocus)
                        .focusedValue(\.ghosttySurfaceTitle, surfaceView.title)
                        .focusedValue(\.ghosttySurfaceView, surfaceView)
                        .focusedValue(\.ghosttySurfaceCellSize, surfaceView.cellSize)
                    #if canImport(AppKit)
                        .onReceive(pubBecomeKey) { notification in
                            guard let window = notification.object as? NSWindow else { return }
                            guard let surfaceWindow = surfaceView.window else { return }
                            windowFocus = surfaceWindow == window
                        }
                        .onReceive(pubResign) { notification in
                            guard let window = notification.object as? NSWindow else { return }
                            guard let surfaceWindow = surfaceView.window else { return }
                            if (surfaceWindow == window) {
                                windowFocus = false
                            }
                        }
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            providers.forEach { provider in
                                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                                    guard let url = url else { return }
                                    let path = Shell.escape(url.path)
                                    DispatchQueue.main.async {
                                        surfaceView.insertText(
                                            path,
                                            replacementRange: NSMakeRange(0, 0)
                                        )
                                    }
                                }
                            }
                            
                            return true
                        }
                    #endif
                        .onReceive(pubBecomeFocused) { notification in
                            // We only want to run this on older macOS versions where the .focused
                            // method doesn't work properly. See the dispatch of this notification
                            // for more information.
                            if #available(macOS 13, *) { return }

                            DispatchQueue.main.async {
                                surfaceFocus = true
                            }
                        }
                        .onAppear() {
                            // Welcome to the SwiftUI bug house of horrors. On macOS 12 (at least
                            // 12.5.1, didn't test other versions), the order in which the view
                            // is added to the window hierarchy is such that $surfaceFocus is
                            // not set to true for the first surface in a window. As a result,
                            // new windows are key (they have window focus) but the terminal surface
                            // does not have surface until the user clicks. Bad!
                            //
                            // There is a very real chance that I am doing something wrong, but it
                            // works great as-is on macOS 13, so I've instead decided to make the
                            // older macOS hacky. A workaround is on initial appearance to "steal
                            // focus" under certain conditions that seem to imply we're in the
                            // screwy state.
                            if #available(macOS 13, *) {
                                // If we're on a more modern version of macOS, do nothing.
                                return
                            }
                            if #available(macOS 12, *) {
                                // On macOS 13, the view is attached to a window at this point,
                                // so this is one extra check that we're a new view and behaving odd.
                                guard surfaceView.window == nil else { return }
                                DispatchQueue.main.async {
                                    surfaceFocus = true
                                }
                            }

                            // I don't know how older macOS versions behave but Ghostty only
                            // supports back to macOS 12 so its moot.
                        }
                }
                .ghosttySurfaceView(surfaceView)
                
                // If we have a URL from hovering a link, we show that.
                if let url = surfaceView.hoverUrl {
                    let padding: CGFloat = 3
                    ZStack {
                        HStack {
                            Spacer()
                            VStack(alignment: .leading) {
                                Spacer()
                                
                                Text(verbatim: url)
                                    .padding(.init(top: padding, leading: padding, bottom: padding, trailing: padding))
                                    .background(.background)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .opacity(isHoveringURLLeft ? 1 : 0)
                            }
                        }
                        
                        HStack {
                            VStack(alignment: .leading) {
                                Spacer()
                                
                                Text(verbatim: url)
                                    .padding(.init(top: padding, leading: padding, bottom: padding, trailing: padding))
                                    .background(.background)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .opacity(isHoveringURLLeft ? 0 : 1)
                                    .onHover(perform: { hovering in
                                        isHoveringURLLeft = hovering
                                    })
                            }
                            Spacer()
                        }
                    }
                }
                
                // If our surface is not healthy, then we render an error view over it.
                if (!surfaceView.healthy) {
                    Rectangle().fill(ghostty.config.backgroundColor)
                    SurfaceRendererUnhealthyView()
                } else if (surfaceView.error != nil) {
                    Rectangle().fill(ghostty.config.backgroundColor)
                    SurfaceErrorView()
                }

                // If we're part of a split view and don't have focus, we put a semi-transparent
                // rectangle above our view to make it look unfocused. We use "surfaceFocus"
                // because we want to keep our focused surface dark even if we don't have window
                // focus.
                if (isSplit && !surfaceFocus) {
                    let overlayOpacity = ghostty.config.unfocusedSplitOpacity;
                    if (overlayOpacity > 0) {
                        Rectangle()
                            .fill(ghostty.config.unfocusedSplitFill)
                            .allowsHitTesting(false)
                            .opacity(overlayOpacity)
                    }
                }
            }
        }
    }
    
    struct SurfaceRendererUnhealthyView: View {
        var body: some View {
            HStack {
                Image("AppIconImage")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128, height: 128)
                
                VStack(alignment: .leading) {
                    Text("Oh, no. 😭").font(.title)
                    Text("""
                        The renderer has failed. This is usually due to exhausting
                        available GPU memory. Please free up available resources.
                        """.replacingOccurrences(of: "\n", with: " ")
                    )
                    .frame(maxWidth: 350)
                }
            }
            .padding()
        }
    }
    
    struct SurfaceErrorView: View {
        var body: some View {
            HStack {
                Image("AppIconImage")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128, height: 128)
                
                VStack(alignment: .leading) {
                    Text("Oh, no. 😭").font(.title)
                    Text("""
                        The terminal failed to initialize. Please check the logs for
                        more information. This is usually a bug.
                        """.replacingOccurrences(of: "\n", with: " ")
                    )
                    .frame(maxWidth: 350)
                }
            }
            .padding()
        }
    }
    
    /// A surface is terminology in Ghostty for a terminal surface, or a place where a terminal is actually drawn
    /// and interacted with. The word "surface" is used because a surface may represent a window, a tab,
    /// a split, a small preview pane, etc. It is ANYTHING that has a terminal drawn to it.
    ///
    /// We just wrap an AppKit NSView here at the moment so that we can behave as low level as possible
    /// since that is what the Metal renderer in Ghostty expects. In the future, it may make more sense to
    /// wrap an MTKView and use that, but for legacy reasons we didn't do that to begin with.
    struct Surface: OSViewRepresentable {
        /// The view to render for the terminal surface.
        let view: SurfaceView

        /// The size of the frame containing this view. We use this to update the the underlying
        /// surface. This does not actually SET the size of our frame, this only sets the size
        /// of our Metal surface for drawing.
        ///
        /// Note: we do NOT use the NSView.resize function because SwiftUI on macOS 12
        /// does not call this callback (macOS 13+ does).
        ///
        /// The best approach is to wrap this view in a GeometryReader and pass in the geo.size.
        let size: CGSize

        func makeOSView(context: Context) -> SurfaceView {
            // We need the view as part of the state to be created previously because
            // the view is sent to the Ghostty API so that it can manipulate it
            // directly since we draw on a render thread.
            return view;
        }

        func updateOSView(_ view: SurfaceView, context: Context) {
            view.sizeDidChange(size)
        }
    }
    
    /// The configuration for a surface. For any configuration not set, defaults will be chosen from
    /// libghostty, usually from the Ghostty configuration.
    struct SurfaceConfiguration {
        /// Explicit font size to use in points
        var fontSize: Float32? = nil
        
        /// Explicit working directory to set
        var workingDirectory: String? = nil
        
        /// Explicit command to set
        var command: String? = nil
        
        init() {}
        
        init(from config: ghostty_surface_config_s) {
            self.fontSize = config.font_size
            self.workingDirectory = String.init(cString: config.working_directory, encoding: .utf8)
            self.command = String.init(cString: config.command, encoding: .utf8)
        }
        
        /// Returns the ghostty configuration for this surface configuration struct. The memory
        /// in the returned struct is only valid as long as this struct is retained.
        func ghosttyConfig(view: SurfaceView) -> ghostty_surface_config_s {
            var config = ghostty_surface_config_new()
            config.userdata = Unmanaged.passUnretained(view).toOpaque()
            #if os(macOS)
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()
            ))
            config.scale_factor = NSScreen.main!.backingScaleFactor
            
            #elseif os(iOS)
            config.platform_tag = GHOSTTY_PLATFORM_IOS
            config.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
                uiview: Unmanaged.passUnretained(view).toOpaque()
            ))
            // Note that UIScreen.main is deprecated and we're supposed to get the
            // screen through the view hierarchy instead. This means that we should
            // probably set this to some default, then modify the scale factor through
            // libghostty APIs when a UIView is attached to a window/scene. TODO.
            config.scale_factor = UIScreen.main.scale
            #else
            #error("unsupported target")
            #endif
            
            if let fontSize = fontSize { config.font_size = fontSize }
            if let workingDirectory = workingDirectory {
                config.working_directory = (workingDirectory as NSString).utf8String
            }
            if let command = command {
                config.command = (command as NSString).utf8String
            }
            
            return config
        }
    }
}

// MARK: Surface Environment Keys

private struct GhosttySurfaceViewKey: EnvironmentKey {
    static let defaultValue: Ghostty.SurfaceView? = nil
}

extension EnvironmentValues {
    var ghosttySurfaceView: Ghostty.SurfaceView? {
        get { self[GhosttySurfaceViewKey.self] }
        set { self[GhosttySurfaceViewKey.self] = newValue }
    }
}

extension View {
    func ghosttySurfaceView(_ surfaceView: Ghostty.SurfaceView?) -> some View {
        environment(\.ghosttySurfaceView, surfaceView)
    }
}

// MARK: Surface Focus Keys

extension FocusedValues {
    var ghosttySurfaceView: Ghostty.SurfaceView? {
        get { self[FocusedGhosttySurface.self] }
        set { self[FocusedGhosttySurface.self] = newValue }
    }

    struct FocusedGhosttySurface: FocusedValueKey {
        typealias Value = Ghostty.SurfaceView
    }
}

extension FocusedValues {
    var ghosttySurfaceTitle: String? {
        get { self[FocusedGhosttySurfaceTitle.self] }
        set { self[FocusedGhosttySurfaceTitle.self] = newValue }
    }

    struct FocusedGhosttySurfaceTitle: FocusedValueKey {
        typealias Value = String
    }
}

extension FocusedValues {
    var ghosttySurfaceZoomed: Bool? {
        get { self[FocusedGhosttySurfaceZoomed.self] }
        set { self[FocusedGhosttySurfaceZoomed.self] = newValue }
    }

    struct FocusedGhosttySurfaceZoomed: FocusedValueKey {
        typealias Value = Bool
    }
}

extension FocusedValues {
    var ghosttySurfaceCellSize: OSSize? {
        get { self[FocusedGhosttySurfaceCellSize.self] }
        set { self[FocusedGhosttySurfaceCellSize.self] = newValue }
    }

    struct FocusedGhosttySurfaceCellSize: FocusedValueKey {
        typealias Value = OSSize
    }
}
