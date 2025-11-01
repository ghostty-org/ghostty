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
    private let scrollView: SurfaceScrollSubView
    private let documentView: NSView
    private let surfaceView: Ghostty.SurfaceView
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var isLiveScrolling = false
    private var currentScrollbar: Ghostty.Action.Scrollbar? = nil
    
    /// The last row position sent via scroll_to_row action. Used to avoid
    /// sending redundant actions when the user drags the scrollbar but stays
    /// on the same row.
    private var lastSentRow: Int?
    
    init(contentSize: CGSize, surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        // The scroll view is our outermost view that controls all our scrollbar
        // rendering and behavior.
        scrollView = SurfaceScrollSubView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.usesPredominantAxisScrolling = true
        // hide default background to show blur effect properly
        scrollView.drawsBackground = false
        
        // The document view is what the scrollview is actually going
        // to be directly scrolling. We set it up to a "blank" NSView
        // with the desired content size.
        documentView = NSView(frame: NSRect(origin: .zero, size: contentSize))
        scrollView.documentView = documentView
        
        // The actual surface view is added as a direct subview of the scroll
        // view. SurfaceScrollSubView automatically maintains the subview order
        // such that the scrollers are drawn on top of the surface, while the
        // fake content and document views are placed below so they won't
        // interfere with mouse events et cetera.
        scrollView.addSubview(surfaceView)
        
        super.init(frame: .zero)
        
        // Our scroll view is our only view
        addSubview(scrollView)
        
        // Apply initial scrollbar settings
        synchronizeAppearance()
        
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
        
        // Listen for derived config changes to update scrollbar settings live
        surfaceView.$derivedConfig
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.synchronizeAppearance()
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        
        // Force layout to be called to fix up our various subviews.
        needsLayout = true
    }
    
    override func layout() {
        super.layout()

        // Fill entire bounds with scroll view and surface view
        scrollView.frame = bounds
        surfaceView.frame = scrollView.bounds
        
        // Only update sizes if we have a valid (non-zero) content size. The content size
        // can be zero when this is added early to a view, or to an invisible hierarchy.
        // Practically, this happened in the quick terminal.
        let contentSize = scrollView.contentSize
        guard contentSize.width > 0 && contentSize.height > 0 else { return }
        
        // Inform the actual pty of our size change, including the scroller
        // width to prevent our rows/cols from going into the non-content area.
        //
        // If we have a legacy scrollbar, then we account for that regardless of
        // whether its currently visible, because legacy scrollbars change our
        // content size and force reflow of our terminal which is not desirable.
        // See: https://github.com/ghostty-org/ghostty/discussions/9254
        let style = scrollView.verticalScroller?.scrollerStyle ?? NSScroller.preferredScrollerStyle
        if (style == .legacy) && scrollView.hasVerticalScroller {
            let scrollerWidth =
                scrollView.verticalScroller?.frame.width
                ?? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            surfaceView.sizeDidChange(surfaceView.frame.size, scrollerInset: scrollerWidth)
        } else {
            surfaceView.sizeDidChange(surfaceView.frame.size, scrollerInset: 0)
        }
        
        // Keep document width synchronized with content width, and update the
        // document height as appropriate for the current surface size.
        documentView.setFrameSize(CGSize(
            width: contentSize.width,
            height: documentHeight(currentScrollbar),
        ))
    }
    
    // MARK: Scrolling
    
    private func synchronizeAppearance() {
        let scrollbarConfig = surfaceView.derivedConfig.scrollbar
        scrollView.hasVerticalScroller = scrollbarConfig != .never
    }
    
    // MARK: Notifications
    
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
        let visibleRect = scrollView.documentVisibleRect
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
        currentScrollbar = scrollbar
        
        // Convert row units to pixels using cell height, ignore zero height.
        let cellHeight = surfaceView.cellSize.height
        guard cellHeight > 0 else { return }

        // Our width should be the content width to account for visible scrollers.
        // We don't do horizontal scrolling in terminals.
        documentView.setFrameSize(CGSize(
            width: scrollView.contentSize.width,
            height: documentHeight(scrollbar),
        ))
        
        // Only update our actual scroll position if we're not actively scrolling.
        if !isLiveScrolling {
            // Invert coordinate system: terminal offset is from top, AppKit position from bottom
            let offsetY = CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
            
            // Track the current row position to avoid redundant movements when we
            // move the scrollbar.
            lastSentRow = Int(scrollbar.offset)
        }
        
        // Always update our scrolled view with the latest dimensions
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Calculate the appropriate document view height given a scrollbar state
    private func documentHeight(_ scrollbar: Ghostty.Action.Scrollbar?) -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = surfaceView.cellSize.height
        if cellHeight > 0, let scrollbar = scrollbar {
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

/// An NSScrollView subclass that keeps SurfaceViews sandwiched between the clip
/// view and scroller, and disables spurious edge effects when the terminal
/// window titlebar is hidden.
///
/// We can't make the surfaceView a subview of the contentView/documentView,
/// because it would clipped and unable to draw the background behind the
/// transparent scroller slot. Instead, we have to make it a direct subview of
/// the NSScrollView and pay attention to its position in the stack. Both
/// visuals and event handling require that it's above the clip view and below
/// the scroller(s).
///
/// The SwiftUI ScrollView host sometimes adds extra styling overlays to the
/// titlebar area, which are incompatible with the hidden titlebar style. Even
/// not present when the app is first opened, they may appear when creating
/// splits or cycling fullscreen. NSScrollView doesn't have a public way to
/// disable this, so we use this subclass to reject them.
/// See https://developer.apple.com/forums/thread/798392.
fileprivate class SurfaceScrollSubView: NSScrollView {
    private var titlebarIsHidden: Bool = false {
        didSet {
            if titlebarIsHidden {
                subviews = subviews.filter({ !$0.className.contains("NSScrollPocket") })
            }
        }
    }
    override func viewDidMoveToWindow() {
        titlebarIsHidden = window is HiddenTitlebarTerminalWindow
    }
    override func addSubview(_ view: NSView) {
        if titlebarIsHidden && view.className.contains("NSScrollPocket") { return }
        super.addSubview(view)
        // maintain order invariant: clipView < surfaceView < scroller
        guard let surfaceIndex = subviews.lastIndex(where: { $0 is Ghostty.SurfaceView }) else {
            return
        }
        if let scrollerIndex = subviews.firstIndex(where: { $0 is NSScroller }) {
            if surfaceIndex > scrollerIndex {
                moveSubview(from: surfaceIndex, to: scrollerIndex)
                // return here because if we ended up in this branch, the next
                // case should be OK, and if that's somehow wrong and we're
                // forced to choose, having a visible scroller is more important
                return
            }
        }
        if let clipViewIndex = subviews.lastIndex(where: { $0 is NSClipView }) {
            if surfaceIndex < clipViewIndex {
                moveSubview(from: surfaceIndex, to: clipViewIndex)
            }
        }
    }
    private func moveSubview(from: Array<NSView>.Index, to: Array<NSView>.Index) {
        var new_subviews = subviews
        let movedView = new_subviews.remove(at: from)
        new_subviews.insert(movedView, at: to)
        subviews = new_subviews
    }
}
