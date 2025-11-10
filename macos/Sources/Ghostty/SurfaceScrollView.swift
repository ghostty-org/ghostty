import SwiftUI
import Combine

/// Wraps a Ghostty surface view in an NSScrollView to provide native macOS scrollbar support.
///
/// ## Coordinate System
/// AppKit uses a +Y-up coordinate system (origin at bottom-left), while terminals conceptually
/// use +Y-down (row 0 at top). This class handles the inversion when converting between row
/// offsets and pixel positions.
///
/// ## Architecture
/// - `scrollView`: The outermost NSScrollView that manages scrollbar rendering and behavior
/// - `documentView`: A blank NSView whose height represents total scrollback (in pixels)
/// - `surfaceView`: The actual Ghostty renderer, positioned to fill the visible rect
class SurfaceScrollView: NSView {
    private let scrollView: NSScrollView
    private let documentView: NSView
    private let surfaceView: Ghostty.SurfaceView
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var isLiveScrolling = false
    
    /// The last row position sent via scroll_to_row action. Used to avoid
    /// sending redundant actions when the user drags the scrollbar but stays
    /// on the same row.
    private var lastSentRow: Int?
    
    init(contentSize: CGSize, surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        // The scroll view is our outermost view that controls all our scrollbar
        // rendering and behavior.
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.usesPredominantAxisScrolling = true
        // hide default background to show blur effect properly
        scrollView.drawsBackground = false
        // don't let the content view clip it's subviews, to enable the
        // surface to draw the background behind non-overlay scrollers
        scrollView.contentView.clipsToBounds = false
        
        // The document view is what the scrollview is actually going
        // to be directly scrolling. We set it up to a "blank" NSView
        // with the desired content size.
        documentView = NSView(frame: NSRect(origin: .zero, size: contentSize))
        scrollView.documentView = documentView
        
        // The document view contains our actual surface as a child.
        // We synchronize the scrolling of the document with this surface
        // so that our primary Ghostty renderer only needs to render the viewport.
        documentView.addSubview(surfaceView)
        
        super.init(frame: .zero)
        
        // Our scroll view is our only view
        addSubview(scrollView)
        
        // Apply initial scrollbar settings
        synchronizeAppearance()
        
        // We listen for scroll events through bounds notifications on our NSClipView.
        // This is based on: https://christiantietze.de/posts/2018/07/synchronize-nsscrollview/
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollChange(notification)
        })
        
        // Listen for scrollbar updates from Ghostty
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollbarUpdate(notification)
        })
        
        // Listen for live scroll events
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = true
        })
        
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = false
        })
        
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.handleLiveScroll()
        })
        
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScrollerStyleChange()
        })

        // Listen for frame change events. See the docstring for
        // handleFrameChange for why this is necessary.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: nil,
            // Since this observer is used to immediately override the event
            // that produced the notification, we let it run synchronously on
            // the posting thread.
            queue: nil
        ) { [weak self] notification in
            self?.handleFrameChange(notification)
        })

        // Listen for derived config changes to update scrollbar settings live
        surfaceView.$derivedConfig
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.handleConfigChange()
                }
            }
            .store(in: &cancellables)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // The entire bounds is a safe area, so we override any default
    // insets. This is necessary for the content view to match the
    // surface view if we have the "hidden" titlebar style.
    override var safeAreaInsets: NSEdgeInsets { return NSEdgeInsetsZero }
    
    override func layout() {
        super.layout()
        
        // Fill entire bounds with scroll view
        scrollView.frame = bounds
        surfaceView.frame.size = scrollView.bounds.size

        // We only set the width of the documentView here, as the height depends
        // on the scrollbar state and is updated in synchronizeScrollView
        documentView.frame.size.width = scrollView.bounds.width
        
        // When our scrollview changes make sure our scroller and surface views are synchronized
        synchronizeScrollView()
        synchronizeSurfaceView()
        synchronizeCoreSurface()
    }
    
    // MARK: Scrolling
    
    private func synchronizeAppearance() {
        let scrollbarConfig = surfaceView.derivedConfig.scrollbar
        scrollView.hasVerticalScroller = scrollbarConfig != .never
    }
    
    /// Positions the surface view to fill the currently visible rectangle.
    ///
    /// This is called whenever the scroll position changes. The surface view (which does the
    /// actual terminal rendering) always fills exactly the visible portion of the document view,
    /// so the renderer only needs to render what's currently on screen.
    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        surfaceView.frame.origin = visibleRect.origin
    }

    /// Inform the actual pty of our size change. This doesn't change the actual view
    /// frame because we do want to render the whole thing, but it will prevent our
    /// rows/cols from going into the non-content area.
    private func synchronizeCoreSurface() {
        // Only update the pty if we have a valid (non-zero) content size. The content size
        // can be zero when this is added early to a view, or to an invisible hierarchy.
        // Practically, this happened in the quick terminal.
        let width = surfaceContentWidth()
        let height = surfaceView.frame.height
        if width > 0 && height > 0 {
            surfaceView.sizeDidChange(CGSize(width: width, height: height))
        }
    }

    /// Sizes the document view and scrolls the content view according to the scrollbar state
    private func synchronizeScrollView() {
        // Update the document height to give our scroller the correct proportions
        documentView.frame.size.height = documentHeight()
        
        // Only update our actual scroll position if we're not actively scrolling.
        if !isLiveScrolling {
            // Convert row units to pixels using cell height, ignore zero height.
            let cellHeight = surfaceView.cellSize.height
            if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
                // Invert coordinate system: terminal offset is from top, AppKit position from bottom
                let offsetY =
                    CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))

                // Track the current row position to avoid redundant movements when we
                // move the scrollbar.
                lastSentRow = Int(scrollbar.offset)
            }
        }
        
        // Always update our scrolled view with the latest dimensions
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    
    // MARK: Notifications
    
    /// Handles bounds changes in the scroll view's clip view, keeping the surface view synchronized.
    private func handleScrollChange(_ notification: Notification) {
        synchronizeSurfaceView()
    }

    /// Handles scrollbar style changes
    private func handleScrollerStyleChange() {
        synchronizeCoreSurface()
    }

    /// Handles config changes
    private func handleConfigChange() {
        synchronizeAppearance()
        synchronizeCoreSurface()
    }
    
    /// Handles live scroll events (user actively dragging the scrollbar).
    ///
    /// Converts the current scroll position to a row number and sends a `scroll_to_row` action
    /// to the terminal core. Only sends actions when the row changes to avoid IPC spam.
    private func handleLiveScroll() {
        // If our cell height is currently zero then we avoid a div by zero below
        // and just don't scroll (there's no where to scroll anyways). This can
        // happen with a tiny terminal.
        let cellHeight = surfaceView.cellSize.height
        guard cellHeight > 0 else { return }
        
        // AppKit views are +Y going up, so we calculate from the bottom
        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.frame.height
        let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height
        let row = Int(scrollOffset / cellHeight)
        
        // Only send action if the row changed to avoid action spam
        guard row != lastSentRow else { return }
        lastSentRow = row
        
        // Use the keybinding action to scroll.
        _ = surfaceView.surfaceModel?.perform(action: "scroll_to_row:\(row)")
    }
    
    /// Handles scrollbar state updates from the terminal core.
    ///
    /// Updates the document view size to reflect total scrollback and adjusts scroll position
    /// to match the terminal's viewport. During live scrolling, updates document size but skips
    /// programmatic position changes to avoid fighting the user's drag.
    ///
    /// ## Scrollbar State
    /// The scrollbar struct contains:
    /// - `total`: Total rows in scrollback + active area
    /// - `offset`: First visible row (0 = top of history)
    /// - `len`: Number of visible rows (viewport height)
    private func handleScrollbarUpdate(_ notification: Notification) {
        guard let scrollbar = notification.userInfo?[SwiftUI.Notification.Name.ScrollbarKey] as? Ghostty.Action.Scrollbar else {
            return
        }
        surfaceView.scrollbar = scrollbar
        synchronizeScrollView()
    }

    /// Handles a change in the frame of NSScrollPocket styling overlays
    ///
    /// NSScrollView instances are set up with a subview hierarchy which, as far
    /// as I can tell, is intended to add a blur effect to any part of a scroll
    /// view that lies under the titlebar, presumably to complement a titlebar
    /// using liquid glass transparency. This doesn't work correctly with our
    /// hidden titlebar style, which does have a titlebar container, albeit
    /// hidden. The styling overlays don't care and size themselves to this
    /// container, creating a blurry, transparent field that clips the top of
    /// the surface view.
    ///
    /// With other titlebar styles, these views always have zero frame size,
    /// presumably because there is no overlap between the scroll view and the
    /// titlebar container.
    ///
    /// In native fullscreen, the titlebar detaches from the window and these
    /// views seem to work a bit differently, taking non-zero sizes for all
    /// styles without creating any problems.
    ///
    /// To handle this in a way that minimizes the difference between how the
    /// hidden titlebar and other window styles behave, we do as follows: If we
    /// have the hidden titlebar style and we're not fullscreen, we listen to
    /// frame changes on NSScrollPocket-related objects in scrollView.subviews,
    /// and reset their frame to zero.
    ///
    /// See also https://developer.apple.com/forums/thread/798392.
    private func handleFrameChange(_ notification: Notification) {
        guard let window = window as? HiddenTitlebarTerminalWindow else { return }
        guard !window.styleMask.contains(.fullScreen) else { return }
        guard let view = notification.object as? NSView else { return }
        guard view.className.contains("NSScrollPocket") else { return }
        guard scrollView.subviews.contains(view) else { return }
        // These guards to avoid an infinite loop don't actually seem necessary.
        // The number of times we reach this point during any given event (e.g.,
        // creating a split) is the same either way. We keep them anyway out of
        // an abundance of caution.
        view.postsFrameChangedNotifications = false
        view.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        view.postsFrameChangedNotifications = true
    }

    // MARK: Calculations

    /// Calculate the content width reported to the core surface
    ///
    /// If we have a legacy scrollbar and its not visible, then we account for that
    /// in advance, because legacy scrollbars change our contentSize and force reflow
    /// of our terminal which is not desirable.
    /// See: https://github.com/ghostty-org/ghostty/discussions/9254
    private func surfaceContentWidth() -> CGFloat {
        let contentWidth = scrollView.contentSize.width
        if scrollView.hasVerticalScroller {
            let style =
                scrollView.verticalScroller?.scrollerStyle
                ?? NSScroller.preferredScrollerStyle
            // We only subtract the scrollbar width if it's hidden or not present,
            // otherwise its width is already accounted for in contentSize.
            if style == .legacy && (scrollView.verticalScroller?.isHidden ?? true) {
                let scrollerWidth =
                    scrollView.verticalScroller?.frame.width
                    ?? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
                return max(0, contentWidth - scrollerWidth)
            }
        }
        return contentWidth
    }

    /// Calculate the appropriate document view height given a scrollbar state
    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = surfaceView.cellSize.height
        if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
            // The document view must have the same vertical padding around the
            // scrollback grid as the content view has around the terminal grid
            // otherwise the content view loses alignment with the surface.
            let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
            let padding = contentHeight - (CGFloat(scrollbar.len) * cellHeight)
            return documentGridHeight + padding
        }
        return contentHeight
    }
}
