import SwiftUI
import UserNotifications
import GhosttyKit

extension Ghostty {
    /// Render a terminal for the active app in the environment.
    struct Terminal: View {
        @EnvironmentObject private var ghostty: Ghostty.App

        var body: some View {
            if let app = self.ghostty.app {
                SurfaceForApp(app) { surfaceView in
                    SurfaceWrapper(surfaceView: surfaceView)
                }
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

        #if canImport(AppKit)
        // Observe SecureInput to detect when its enabled
        @ObservedObject private var secureInput = SecureInput.shared
        #endif

        @EnvironmentObject private var ghostty: Ghostty.App
        @Environment(\.ghosttyLastFocusedSurface) private var lastFocusedSurface

        private var isFocusedSurface: Bool {
            surfaceFocus || lastFocusedSurface?.value === surfaceView
        }

        var body: some View {
            let center = NotificationCenter.default

            ZStack {
                // We use a GeometryReader to get the frame bounds so that our metal surface
                // is up to date. See TerminalSurfaceView for why we don't use the NSView
                // resize callback.
                GeometryReader { geo in
                    #if canImport(AppKit)
                    let pubBecomeKey = center.publisher(for: NSWindow.didBecomeKeyNotification)
                    let pubResign = center.publisher(for: NSWindow.didResignKeyNotification)
                    #endif

                    SurfaceRepresentable(view: surfaceView, size: geo.size)
                        .focused($surfaceFocus)
                        .focusedValue(\.ghosttySurfacePwd, surfaceView.pwd)
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
                            if surfaceWindow == window {
                                windowFocus = false
                            }
                        }
                    #endif

                    // If our geo size changed then we show the resize overlay as configured.
                    if let surfaceSize = surfaceView.surfaceSize {
                        SurfaceResizeOverlay(
                            geoSize: geo.size,
                            size: surfaceSize,
                            overlay: ghostty.config.resizeOverlay,
                            position: ghostty.config.resizeOverlayPosition,
                            duration: ghostty.config.resizeOverlayDuration,
                            focusInstant: surfaceView.focusInstant)

                    }
                }
                .ghosttySurfaceView(surfaceView)

                // Progress report
                if let progressReport = surfaceView.progressReport, progressReport.state != .remove {
                    VStack(spacing: 0) {
                        SurfaceProgressBar(report: progressReport)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

#if canImport(AppKit)
                // Readonly indicator badge
                if surfaceView.readonly {
                    ReadonlyBadge {
                        surfaceView.toggleReadonly(nil)
                    }
                }

                // Show key state indicator for active key tables and/or pending key sequences
                KeyStateIndicator(
                    keyTables: surfaceView.keyTables,
                    keySequence: surfaceView.keySequence
                )
#endif

                // If we have a URL from hovering a link, we show that.
                if let url = surfaceView.hoverUrl {
                    let padding: CGFloat = 5
                    let cornerRadius: CGFloat = 9
                    ZStack {
                        HStack {
                            Spacer()
                            VStack(alignment: .leading) {
                                Spacer()

                                Text(verbatim: url)
                                    .padding(.init(top: padding, leading: padding, bottom: padding, trailing: padding))
                                    .background(
                                        UnevenRoundedRectangle(cornerRadii: .init(topLeading: cornerRadius))
                                            .fill(.background)
                                    )
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
                                    .background(
                                        UnevenRoundedRectangle(cornerRadii: .init(topTrailing: cornerRadius))
                                            .fill(.background)
                                    )
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

                #if canImport(AppKit)
                // If we have secure input enabled and we're the focused surface and window
                // then we want to show the secure input overlay.
                if ghostty.config.secureInputIndication &&
                    secureInput.enabled &&
                    surfaceFocus &&
                    windowFocus {
                    SecureInputOverlay()
                }
                #endif

                // Search overlay
                if let searchState = surfaceView.searchState {
                    SurfaceSearchOverlay(
                        surfaceView: surfaceView,
                        searchState: searchState,
                        onClose: {
#if canImport(AppKit)
                            Ghostty.moveFocus(to: surfaceView)
#endif
                            surfaceView.searchState = nil
                        }
                    )
                }

                // Show bell border if enabled
                if ghostty.config.bellFeatures.contains(.border) {
                    BellBorderOverlay(bell: surfaceView.bell)
                }

                // Show a highlight effect when this surface needs attention
                HighlightOverlay(highlighted: surfaceView.highlighted)

                // If our surface is not healthy, then we render an error view over it.
                if !surfaceView.healthy {
                    Rectangle().fill(ghostty.config.backgroundColor)
                    SurfaceRendererUnhealthyView()
                } else if surfaceView.error != nil {
                    Rectangle().fill(ghostty.config.backgroundColor)
                    SurfaceErrorView()
                }

                // If we're part of a split view and don't have focus, we put a semi-transparent
                // rectangle above our view to make it look unfocused. We include the last
                // focused surface so this still works while SwiftUI focus is temporarily nil.
                if isSplit && !isFocusedSurface {
                    let overlayOpacity = ghostty.config.unfocusedSplitOpacity
                    if overlayOpacity > 0 {
                        Rectangle()
                            .fill(ghostty.config.unfocusedSplitFill)
                            .allowsHitTesting(false)
                            .opacity(overlayOpacity)
                    }
                }

                #if canImport(AppKit)
                // Grab handle for dragging the window. We want this to appear at the very
                // top Z-index os it isn't faded by the unfocused overlay.
                //
                // This is disabled except on macOS because it uses AppKit drag/drop APIs.
                SurfaceGrabHandle(surfaceView: surfaceView)
                #endif
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

    // This is the resize overlay that shows on top of a surface to show the current
    // size during a resize operation.
    struct SurfaceResizeOverlay: View {
        let geoSize: CGSize
        let size: ghostty_surface_size_s
        let overlay: Ghostty.Config.ResizeOverlay
        let position: Ghostty.Config.ResizeOverlayPosition
        let duration: UInt
        let focusInstant: ContinuousClock.Instant?

        // This is the last size that we processed. This is how we handle our
        // timer state.
        @State var lastSize: CGSize?

        // Ready is set to true after a short delay. This avoids some of the
        // challenges of initial view sizing from SwiftUI.
        @State var ready: Bool = false

        // Fixed value set based on personal taste.
        private let padding: CGFloat = 5

        // This computed boolean is set to true when the overlay should be hidden.
        private var hidden: Bool {
            // If we aren't ready yet then we wait...
            if !ready { return true; }

            // Hidden if we already processed this size.
            if lastSize == geoSize { return true; }

            // If we were focused recently we hide it as well. This avoids showing
            // the resize overlay when SwiftUI is lazily resizing.
            if let instant = focusInstant {
                let d = instant.duration(to: ContinuousClock.now)
                if d < .milliseconds(500) {
                    // Avoid this size completely. We can't set values during
                    // view updates so we have to defer this to another tick.
                    DispatchQueue.main.async {
                        lastSize = geoSize
                    }

                    return true
                }
            }

            // Hidden depending on overlay config
            switch overlay {
            case .never: return true
            case .always: return false
            case .after_first: return lastSize == nil
            }
        }

        var body: some View {
            VStack {
                if !position.top() {
                    Spacer()
                }

                HStack {
                    if !position.left() {
                        Spacer()
                    }

                    Text(verbatim: "\(size.columns) ⨯ \(size.rows)")
                        .padding(.init(top: padding, leading: padding, bottom: padding, trailing: padding))
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.background)
                                .shadow(radius: 3)
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if !position.right() {
                        Spacer()
                    }
                }

                if !position.bottom() {
                    Spacer()
                }
            }
            .allowsHitTesting(false)
            .opacity(hidden ? 0 : 1)
            .task {
                // Sleep chosen arbitrarily... a better long term solution would be to detect
                // when the size stabilizes (coalesce a value) for the first time and then after
                // that show the resize overlay consistently.
                try? await Task.sleep(nanoseconds: 500 * 1_000_000)
                ready = true
            }
            .task(id: geoSize) {
                // By ID-ing the task on the geoSize, we get the task to restart if our
                // geoSize changes. This also ensures that future resize overlays are shown
                // properly.

                // We only sleep if we're ready. If we're not ready then we want to set
                // our last size right away to avoid a flash.
                if ready {
                    try? await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000)
                }

                lastSize = geoSize
            }
        }
    }

    /// Search overlay view that displays a search bar with input field and navigation buttons.
    struct SurfaceSearchOverlay: View {
        let surfaceView: SurfaceView
        @ObservedObject var searchState: SurfaceView.SearchState
        let onClose: () -> Void
        @State private var corner: Corner = .topRight
        @State private var dragOffset: CGSize = .zero
        @State private var barSize: CGSize = .zero
        @FocusState private var isSearchFieldFocused: Bool

        private let padding: CGFloat = 8

        var body: some View {
            GeometryReader { geo in
                HStack(spacing: 4) {
                    TextField("Search", text: $searchState.needle)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
                    .padding(.leading, 8)
                    .padding(.trailing, 50)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.1))
                    .cornerRadius(6)
                    .focused($isSearchFieldFocused)
                    .overlay(alignment: .trailing) {
                        if let selected = searchState.selected {
                            Text("\(selected + 1)/\(searchState.total, default: "?")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .padding(.trailing, 8)
                        } else if let total = searchState.total {
                            Text("-/\(total)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .padding(.trailing, 8)
                        }
                    }
#if canImport(AppKit)
                    .onExitCommand {
                        if searchState.needle.isEmpty {
                            onClose()
                        } else {
                            Ghostty.moveFocus(to: surfaceView)
                        }
                    }
#endif
                    .backport.onKeyPress(.return) { modifiers in
                        guard let surface = surfaceView.surface else { return .ignored }
                        let action = modifiers.contains(.shift)
                        ? "navigate_search:previous"
                        : "navigate_search:next"
                        ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
                        return .handled
                    }

                    Button(action: {
                        guard let surface = surfaceView.surface else { return }
                        let action = "navigate_search:next"
                        ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
                    }, label: {
                        Image(systemName: "chevron.up")
                    })
                    .buttonStyle(SearchButtonStyle())

                    Button(action: {
                        guard let surface = surfaceView.surface else { return }
                        let action = "navigate_search:previous"
                        ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
                    }, label: {
                        Image(systemName: "chevron.down")
                    })
                    .buttonStyle(SearchButtonStyle())

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(SearchButtonStyle())
                }
                .padding(8)
                .background(.background)
                .clipShape(clipShape)
                .shadow(radius: 4)
                .onAppear {
                    isSearchFieldFocused = true
                }
                .onReceive(NotificationCenter.default.publisher(for: .ghosttySearchFocus)) { notification in
                    guard notification.object as? SurfaceView === surfaceView else { return }
                    DispatchQueue.main.async {
                        isSearchFieldFocused = true
                    }
                }
                .background(
                    GeometryReader { barGeo in
                        Color.clear.onAppear {
                            barSize = barGeo.size
                        }
                    }
                )
                .padding(padding)
                .offset(dragOffset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragOffset = value.translation
                        }
                        .onEnded { value in
                            let centerPos = centerPosition(for: corner, in: geo.size, barSize: barSize)
                            let newCenter = CGPoint(
                                x: centerPos.x + value.translation.width,
                                y: centerPos.y + value.translation.height
                            )
                            let newCorner = closestCorner(to: newCenter, in: geo.size)
                            withAnimation(.easeOut(duration: 0.2)) {
                                corner = newCorner
                                dragOffset = .zero
                            }
                        }
                )
            }
        }

        private var clipShape: some Shape {
            if #available(iOS 26.0, macOS 26.0, *) {
                return ConcentricRectangle(corners: .concentric(minimum: 8), isUniform: true)
            } else {
                return RoundedRectangle(cornerRadius: 8)
            }
        }

        enum Corner {
            case topLeft, topRight, bottomLeft, bottomRight

            var alignment: Alignment {
                switch self {
                case .topLeft: return .topLeading
                case .topRight: return .topTrailing
                case .bottomLeft: return .bottomLeading
                case .bottomRight: return .bottomTrailing
                }
            }
        }

        private func centerPosition(for corner: Corner, in containerSize: CGSize, barSize: CGSize) -> CGPoint {
            let halfWidth = barSize.width / 2 + padding
            let halfHeight = barSize.height / 2 + padding

            switch corner {
            case .topLeft:
                return CGPoint(x: halfWidth, y: halfHeight)
            case .topRight:
                return CGPoint(x: containerSize.width - halfWidth, y: halfHeight)
            case .bottomLeft:
                return CGPoint(x: halfWidth, y: containerSize.height - halfHeight)
            case .bottomRight:
                return CGPoint(x: containerSize.width - halfWidth, y: containerSize.height - halfHeight)
            }
        }

        private func closestCorner(to point: CGPoint, in containerSize: CGSize) -> Corner {
            let midX = containerSize.width / 2
            let midY = containerSize.height / 2

            if point.x < midX {
                return point.y < midY ? .topLeft : .bottomLeft
            } else {
                return point.y < midY ? .topRight : .bottomRight
            }
        }

        struct SearchButtonStyle: ButtonStyle {
            @State private var isHovered = false

            func makeBody(configuration: Configuration) -> some View {
                configuration.label
                    .foregroundStyle(isHovered || configuration.isPressed ? .primary : .secondary)
                    .padding(.horizontal, 2)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(backgroundColor(isPressed: configuration.isPressed))
                    )
                    .onHover { hovering in
                        isHovered = hovering
                    }
                    .backport.pointerStyle(.link)
            }

            private func backgroundColor(isPressed: Bool) -> Color {
                if isPressed {
                    return Color.primary.opacity(0.2)
                } else if isHovered {
                    return Color.primary.opacity(0.1)
                } else {
                    return Color.clear
                }
            }
        }
    }

    /// A surface is terminology in Ghostty for a terminal surface, or a place where a terminal is actually drawn
    /// and interacted with. The word "surface" is used because a surface may represent a window, a tab,
    /// a split, a small preview pane, etc. It is ANYTHING that has a terminal drawn to it.
    struct SurfaceRepresentable: OSViewRepresentable {
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

        #if canImport(AppKit)
        func makeOSView(context: Context) -> SurfaceScrollView {
            // On macOS, wrap the surface view in a scroll view
            return SurfaceScrollView(contentSize: size, surfaceView: view)
        }

        func updateOSView(_ scrollView: SurfaceScrollView, context: Context) {
            // Nothing to do: SwiftUI automatically updates the frame size, and
            // SurfaceScrollView handles the rest in response to that
        }
        #else
        func makeOSView(context: Context) -> SurfaceView {
            // On iOS, return the surface view directly
            return view
        }

        func updateOSView(_ view: SurfaceView, context: Context) {
            view.sizeDidChange(size)
        }
        #endif
    }

    /// The configuration for a surface. For any configuration not set, defaults will be chosen from
    /// libghostty, usually from the Ghostty configuration.
    struct SurfaceConfiguration {
        /// Explicit font size to use in points
        var fontSize: Float32?

        /// Explicit working directory to set
        var workingDirectory: String?

        /// Explicit command to set
        var command: String?

        /// Environment variables to set for the terminal
        var environmentVariables: [String: String] = [:]

        /// Extra input to send as stdin
        var initialInput: String?

        /// Wait after the command
        var waitAfterCommand: Bool = false

        /// Context for surface creation
        var context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW

        init() {}

        init(from config: ghostty_surface_config_s) {
            self.fontSize = config.font_size
            if let workingDirectory = config.working_directory {
                self.workingDirectory = String.init(cString: workingDirectory, encoding: .utf8)
            }
            if let command = config.command {
                self.command = String.init(cString: command, encoding: .utf8)
            }

            // Convert the C env vars to Swift dictionary
            if config.env_var_count > 0, let envVars = config.env_vars {
                for i in 0..<config.env_var_count {
                    let envVar = envVars[i]
                    if let key = String(cString: envVar.key, encoding: .utf8),
                       let value = String(cString: envVar.value, encoding: .utf8) {
                        self.environmentVariables[key] = value
                    }
                }
            }
            self.context = config.context
        }

        /// Provides a C-compatible ghostty configuration within a closure. The configuration
        /// and all its string pointers are only valid within the closure.
        func withCValue<T>(view: SurfaceView, _ body: (inout ghostty_surface_config_s) throws -> T) rethrows -> T {
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

            // Zero is our default value that means to inherit the font size.
            config.font_size = fontSize ?? 0

            // Set wait after command
            config.wait_after_command = waitAfterCommand

            // Set context
            config.context = context

            // Use withCString to ensure strings remain valid for the duration of the closure
            return try workingDirectory.withCString { cWorkingDir in
                config.working_directory = cWorkingDir

                return try command.withCString { cCommand in
                    config.command = cCommand

                    return try initialInput.withCString { cInput in
                        config.initial_input = cInput

                        // Convert dictionary to arrays for easier processing
                        let keys = Array(environmentVariables.keys)
                        let values = Array(environmentVariables.values)

                        // Create C strings for all keys and values
                        return try keys.withCStrings { keyCStrings in
                            return try values.withCStrings { valueCStrings in
                                // Create array of ghostty_env_var_s
                                var envVars = [ghostty_env_var_s]()
                                envVars.reserveCapacity(environmentVariables.count)
                                for i in 0..<environmentVariables.count {
                                    envVars.append(ghostty_env_var_s(
                                        key: keyCStrings[i],
                                        value: valueCStrings[i]
                                    ))
                                }

                                return try envVars.withUnsafeMutableBufferPointer { buffer in
                                    config.env_vars = buffer.baseAddress
                                    config.env_var_count = environmentVariables.count
                                    return try body(&config)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

#if canImport(AppKit)
    /// Floating indicator that shows active key tables and pending key sequences.
    /// Displayed as a compact draggable pill that can be positioned at the top or bottom.
    struct KeyStateIndicator: View {
        let keyTables: [String]
        let keySequence: [KeyboardShortcut]

        @State private var isShowingPopover = false
        @State private var position: Position = .bottom
        @State private var dragOffset: CGSize = .zero
        @State private var isDragging = false

        private let padding: CGFloat = 8

        enum Position {
            case top, bottom

            var alignment: Alignment {
                switch self {
                case .top: return .top
                case .bottom: return .bottom
                }
            }

            var popoverEdge: Edge {
                switch self {
                case .top: return .top
                case .bottom: return .bottom
                }
            }

            var transitionEdge: Edge {
                popoverEdge
            }
        }

        var body: some View {
            Group {
                if !keyTables.isEmpty || !keySequence.isEmpty {
                    content
                        .backport.pointerStyle(!keyTables.isEmpty ? .link : nil)
                }
            }
            .transition(.move(edge: position.transitionEdge).combined(with: .opacity))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: keyTables)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: keySequence.count)
        }

        var content: some View {
            indicatorContent
                .offset(dragOffset)
                .padding(padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: position.alignment)
                .highPriorityGesture(
                    DragGesture(coordinateSpace: .local)
                        .onChanged { value in
                            isDragging = true
                            dragOffset = CGSize(width: 0, height: value.translation.height)
                        }
                        .onEnded { value in
                            isDragging = false
                            let dragThreshold: CGFloat = 50

                            withAnimation(.easeOut(duration: 0.2)) {
                                if position == .bottom && value.translation.height < -dragThreshold {
                                    position = .top
                                } else if position == .top && value.translation.height > dragThreshold {
                                    position = .bottom
                                }
                                dragOffset = .zero
                            }
                        }
                )
        }

        @ViewBuilder
        private var indicatorContent: some View {
            HStack(alignment: .center, spacing: 8) {
                // Key table indicator
                if !keyTables.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "keyboard.badge.ellipsis")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)

                        // Show table stack with arrows between them
                        ForEach(Array(keyTables.enumerated()), id: \.offset) { index, table in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(verbatim: table)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                        }
                    }
                }

                // Separator when both are active
                if !keyTables.isEmpty && !keySequence.isEmpty {
                    Divider()
                        .frame(height: 14)
                }

                // Key sequence indicator
                if !keySequence.isEmpty {
                    HStack(alignment: .center, spacing: 4) {
                        ForEach(Array(keySequence.enumerated()), id: \.offset) { _, key in
                            KeyCap(key.description)
                        }

                        // Animated ellipsis to indicate waiting for next key
                        PendingIndicator(paused: isDragging)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(.regularMaterial)
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            }
            .contentShape(Capsule())
            .backport.pointerStyle(.link)
            .popover(isPresented: $isShowingPopover, arrowEdge: position.popoverEdge) {
                VStack(alignment: .leading, spacing: 8) {
                    if !keyTables.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Key Table", systemImage: "keyboard.badge.ellipsis")
                                .font(.headline)
                            Text("A key table is a named set of keybindings, activated by some other key. Keys are interpreted using this table until it is deactivated.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !keyTables.isEmpty && !keySequence.isEmpty {
                        Divider()
                    }

                    if !keySequence.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Key Sequence", systemImage: "character.cursor.ibeam")
                                .font(.headline)
                            Text("A key sequence is a series of key presses that trigger an action. A pending key sequence is currently active.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
            }
            .onTapGesture {
                isShowingPopover.toggle()
            }
        }

        /// A small keycap-style view for displaying keyboard shortcuts
        struct KeyCap: View {
            let text: String

            init(_ text: String) {
                self.text = text
            }

            var body: some View {
                Text(verbatim: text)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                    )
            }
        }

        /// Animated dots to indicate waiting for the next key
        struct PendingIndicator: View {
            @State private var animationPhase: Double = 0
            let paused: Bool

            var body: some View {
                TimelineView(.animation(paused: paused)) { context in
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 4, height: 4)
                                .opacity(dotOpacity(for: index))
                        }
                    }
                    .onChange(of: context.date.timeIntervalSinceReferenceDate) { newValue in
                        animationPhase = newValue
                    }
                }
            }

            private func dotOpacity(for index: Int) -> Double {
                let phase = animationPhase
                let offset = Double(index) / 3.0
                let wave = sin((phase + offset) * .pi * 2)
                return 0.3 + 0.7 * ((wave + 1) / 2)
            }
        }
    }
#endif

    /// Visual overlay that shows a border around the edges when the bell rings with border feature enabled.
    struct BellBorderOverlay: View {
        let bell: Bool

        var body: some View {
            Rectangle()
                .strokeBorder(
                    Color(red: 1.0, green: 0.8, blue: 0.0).opacity(0.5),
                    lineWidth: 3
                )
                .allowsHitTesting(false)
                .opacity(bell ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.3), value: bell)
        }
    }

    /// Visual overlay that briefly highlights a surface to draw attention to it.
    /// Uses a soft, soothing highlight with a pulsing border effect.
    struct HighlightOverlay: View {
        let highlighted: Bool

        @State private var borderPulse: Bool = false

        var body: some View {
            ZStack {
                Rectangle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color.accentColor.opacity(0.12),
                                Color.accentColor.opacity(0.03),
                                Color.clear
                            ]),
                            center: .center,
                            startRadius: 0,
                            endRadius: 2000
                        )
                    )

                Rectangle()
                    .strokeBorder(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.accentColor.opacity(0.8),
                                Color.accentColor.opacity(0.5),
                                Color.accentColor.opacity(0.8)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: borderPulse ? 4 : 2
                    )
                    .shadow(color: Color.accentColor.opacity(borderPulse ? 0.8 : 0.6), radius: borderPulse ? 12 : 8, x: 0, y: 0)
                    .shadow(color: Color.accentColor.opacity(borderPulse ? 0.5 : 0.3), radius: borderPulse ? 24 : 16, x: 0, y: 0)
            }
            .allowsHitTesting(false)
            .opacity(highlighted ? 1.0 : 0.0)
            .animation(.easeOut(duration: 0.4), value: highlighted)
            .onChange(of: highlighted) { newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                        borderPulse = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.4)) {
                        borderPulse = false
                    }
                }
            }
        }
    }

    // MARK: Readonly Badge

    /// A badge overlay that indicates a surface is in readonly mode.
    /// Positioned in the top-right corner and styled to be noticeable but unobtrusive.
    struct ReadonlyBadge: View {
        let onDisable: () -> Void

        @State private var showingPopover = false

        private let badgeColor = Color(hue: 0.08, saturation: 0.5, brightness: 0.8)

        var body: some View {
            VStack {
                HStack {
                    Spacer()

                    HStack(spacing: 5) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 12))
                        Text("Read-only")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(badgeBackground)
                    .foregroundStyle(badgeColor)
                    .onTapGesture {
                        showingPopover = true
                    }
                    .backport.pointerStyle(.link)
                    .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                        ReadonlyPopoverView(onDisable: onDisable, isPresented: $showingPopover)
                    }
                }
                .padding(8)

                Spacer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Read-only terminal")
        }

        private var badgeBackground: some View {
            RoundedRectangle(cornerRadius: 6)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.orange.opacity(0.6), lineWidth: 1.5)
                )
        }
    }

    struct ReadonlyPopoverView: View {
        let onDisable: () -> Void
        @Binding var isPresented: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 13))
                        Text("Read-Only Mode")
                            .font(.system(size: 13, weight: .semibold))
                    }

                    Text("This terminal is in read-only mode. You can still view, select, and scroll through the content, but no input events will be sent to the running application.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()

                    Button("Disable") {
                        onDisable()
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(16)
            .frame(width: 280)
        }
    }

    #if canImport(AppKit)
    /// When changing the split state, or going full screen (native or non), the terminal view
    /// will lose focus. There has to be some nice SwiftUI-native way to fix this but I can't
    /// figure it out so we're going to do this hacky thing to bring focus back to the terminal
    /// that should have it.
    static func moveFocus(
        to: SurfaceView,
        from: SurfaceView? = nil,
        delay: TimeInterval? = nil
    ) {
        // The whole delay machinery is a bit of a hack to work around a
        // situation where the window is destroyed and the surface view
        // will never be attached to a window. Realistically, we should
        // handle this upstream but we also don't want this function to be
        // a source of infinite loops.

        // Our max delay before we give up
        let maxDelay: TimeInterval = 0.5
        guard (delay ?? 0) < maxDelay else { return }

        // We start at a 50 millisecond delay and do a doubling backoff
        let nextDelay: TimeInterval = if let delay {
            delay * 2
        } else {
            // 100 milliseconds
            0.05
        }

        let work: DispatchWorkItem = .init {
            // If the callback runs before the surface is attached to a view
            // then the window will be nil. We just reschedule in that case.
            guard let window = to.window else {
                moveFocus(to: to, from: from, delay: nextDelay)
                return
            }

            // If we had a previously focused node and its not where we're sending
            // focus, make sure that we explicitly tell it to lose focus. In theory
            // we should NOT have to do this but the focus callback isn't getting
            // called for some reason.
            if let from = from {
                _ = from.resignFirstResponder()
            }

            window.makeFirstResponder(to)
        }

        let queue = DispatchQueue.main
        if let delay {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            queue.async(execute: work)
        }
    }
    #endif
}

// MARK: Surface Environment Keys

private struct GhosttySurfaceViewKey: EnvironmentKey {
    static let defaultValue: Ghostty.SurfaceView? = nil
}

private struct GhosttyLastFocusedSurfaceKey: EnvironmentKey {
    /// Optional read-only last-focused surface reference. If a surface view is currently focused this
    /// is equal to the currently focused surface.
    static let defaultValue: Weak<Ghostty.SurfaceView>? = nil
}

extension EnvironmentValues {
    var ghosttySurfaceView: Ghostty.SurfaceView? {
        get { self[GhosttySurfaceViewKey.self] }
        set { self[GhosttySurfaceViewKey.self] = newValue }
    }

    var ghosttyLastFocusedSurface: Weak<Ghostty.SurfaceView>? {
        get { self[GhosttyLastFocusedSurfaceKey.self] }
        set { self[GhosttyLastFocusedSurfaceKey.self] = newValue }
    }
}

extension View {
    func ghosttySurfaceView(_ surfaceView: Ghostty.SurfaceView?) -> some View {
        environment(\.ghosttySurfaceView, surfaceView)
    }

    /// The most recently focused surface (can be currently focused if the surface is currently focused).
    func ghosttyLastFocusedSurface(_ surfaceView: Weak<Ghostty.SurfaceView>?) -> some View {
        environment(\.ghosttyLastFocusedSurface, surfaceView)
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

    var ghosttySurfacePwd: String? {
        get { self[FocusedGhosttySurfacePwd.self] }
        set { self[FocusedGhosttySurfacePwd.self] = newValue }
    }

    struct FocusedGhosttySurfacePwd: FocusedValueKey {
        typealias Value = String
    }

    var ghosttySurfaceCellSize: OSSize? {
        get { self[FocusedGhosttySurfaceCellSize.self] }
        set { self[FocusedGhosttySurfaceCellSize.self] = newValue }
    }

    struct FocusedGhosttySurfaceCellSize: FocusedValueKey {
        typealias Value = OSSize
    }
}

// MARK: Search State

extension Ghostty.SurfaceView {
    class SearchState: ObservableObject {
        @Published var needle: String = ""
        @Published var selected: UInt?
        @Published var total: UInt?

        init(from startSearch: Ghostty.Action.StartSearch) {
            self.needle = startSearch.needle ?? ""
        }
    }
}
