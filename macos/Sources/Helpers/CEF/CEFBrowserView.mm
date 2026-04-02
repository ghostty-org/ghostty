#import "CEFBrowserView.h"
#import "CEFBridge.h"
#import <AppKit/AppKit.h>

// CEF headers are only available after running scripts/download-cef.sh.
// When absent, the view compiles in stub mode — all methods are no-ops.
#define GHOSTTIES_CEF_AVAILABLE __has_include("include/cef_browser.h")

#if GHOSTTIES_CEF_AVAILABLE
#import "include/cef_browser.h"
#import "include/cef_client.h"
#import "include/cef_life_span_handler.h"
#import "include/cef_display_handler.h"
#import "include/cef_load_handler.h"
#import "include/wrapper/cef_helpers.h"
#endif

// ---------------------------------------------------------------------------
// URL scheme allowlist — only http, https, and about are permitted.
// ---------------------------------------------------------------------------

static BOOL GhosttiesIsAllowedScheme(NSString *urlString) {
    if (!urlString || urlString.length == 0) return NO;
    NSString *lower = [urlString lowercaseString];
    return [lower hasPrefix:@"https://"]
        || [lower hasPrefix:@"http://"]
        || [lower hasPrefix:@"about:"];
}

#if GHOSTTIES_CEF_AVAILABLE
static bool GhosttiesIsAllowedSchemeCef(const CefString &url) {
    if (url.empty()) return false;
    std::string s = url.ToString();
    // Convert only the scheme portion to lowercase for comparison.
    std::string lower;
    lower.reserve(8);
    for (size_t i = 0; i < s.size() && i < 8; ++i) {
        lower += static_cast<char>(tolower(static_cast<unsigned char>(s[i])));
    }
    return lower.compare(0, 8, "https://") == 0
        || lower.compare(0, 7, "http://") == 0
        || lower.compare(0, 6, "about:") == 0;
}
#endif

// Forward-declare private methods so C++ handlers can call them.
@interface CEFBrowserView ()
- (void)_didChangeURL:(NSString *)url;
- (void)_didChangeTitle:(NSString *)title;
- (void)_didChangeLoadingState:(BOOL)loading canGoBack:(BOOL)back canGoForward:(BOOL)forward;
#if GHOSTTIES_CEF_AVAILABLE
- (void)_browserDidCreate:(CefRefPtr<CefBrowser>)browser;
- (void)_browserDidClose;
#endif
@end

#if GHOSTTIES_CEF_AVAILABLE

#pragma mark - GhosttiesDisplayHandler

class GhosttiesDisplayHandler : public CefDisplayHandler {
public:
    explicit GhosttiesDisplayHandler(CEFBrowserView *view) : view_(view) {}

    void OnAddressChange(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         const CefString &url) override {
        if (!frame->IsMain()) return;
        CEFBrowserView *v = view_;
        if (!v) return;
        NSString *nsURL = [NSString stringWithUTF8String:url.ToString().c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            [v _didChangeURL:nsURL];
        });
    }

    void OnTitleChange(CefRefPtr<CefBrowser> browser,
                       const CefString &title) override {
        CEFBrowserView *v = view_;
        if (!v) return;
        NSString *nsTitle = [NSString stringWithUTF8String:title.ToString().c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            [v _didChangeTitle:nsTitle];
        });
    }

private:
    __weak CEFBrowserView *view_;
    IMPLEMENT_REFCOUNTING(GhosttiesDisplayHandler);
};

#pragma mark - GhosttiesLoadHandler

class GhosttiesLoadHandler : public CefLoadHandler {
public:
    explicit GhosttiesLoadHandler(CEFBrowserView *view) : view_(view) {}

    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                              bool isLoading,
                              bool canGoBack,
                              bool canGoForward) override {
        CEFBrowserView *v = view_;
        if (!v) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [v _didChangeLoadingState:isLoading
                            canGoBack:canGoBack
                         canGoForward:canGoForward];
        });
    }

private:
    __weak CEFBrowserView *view_;
    IMPLEMENT_REFCOUNTING(GhosttiesLoadHandler);
};

#pragma mark - GhosttiesLifeSpanHandler

class GhosttiesLifeSpanHandler : public CefLifeSpanHandler {
public:
    explicit GhosttiesLifeSpanHandler(CEFBrowserView *view) : view_(view) {}

    // Intercept all popups — user-gesture popups navigate the current browser
    // instead of opening a new window; non-user-gesture popups are blocked
    // entirely to prevent uncontrolled popup windows.
    bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       int popup_id,
                       const CefString& target_url,
                       const CefString& target_frame_name,
                       CefLifeSpanHandler::WindowOpenDisposition target_disposition,
                       bool user_gesture,
                       const CefPopupFeatures& popupFeatures,
                       CefWindowInfo& windowInfo,
                       CefRefPtr<CefClient>& client,
                       CefBrowserSettings& settings,
                       CefRefPtr<CefDictionaryValue>& extra_info,
                       bool* no_javascript_access) override {
        // Redirect explicit user clicks (target=_blank links) to current browser.
        if (user_gesture && !target_url.empty()) {
            // Block disallowed schemes (file://, javascript://, data://, etc.).
            if (!GhosttiesIsAllowedSchemeCef(target_url)) {
                NSLog(@"[CEFBrowserView] Blocked popup with disallowed scheme: %s",
                      target_url.ToString().c_str());
                return true;  // Cancel the popup.
            }
            browser->GetMainFrame()->LoadURL(target_url);
            return true;
        }
        return true;  // Block all non-user-gesture popups.
    }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        CEFBrowserView *v = view_;
        if (v) {
            [v _browserDidCreate:browser];
        }
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        CEFBrowserView *v = view_;
        if (v) {
            [v _browserDidClose];
        }
    }

private:
    __weak CEFBrowserView *view_;
    IMPLEMENT_REFCOUNTING(GhosttiesLifeSpanHandler);
};

#pragma mark - GhosttiesCefClient

class GhosttiesCefClient : public CefClient {
public:
    GhosttiesCefClient(CEFBrowserView *view)
        : life_span_handler_(new GhosttiesLifeSpanHandler(view))
        , display_handler_(new GhosttiesDisplayHandler(view))
        , load_handler_(new GhosttiesLoadHandler(view)) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override {
        return life_span_handler_;
    }

    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override {
        return display_handler_;
    }

    CefRefPtr<CefLoadHandler> GetLoadHandler() override {
        return load_handler_;
    }

private:
    CefRefPtr<GhosttiesLifeSpanHandler> life_span_handler_;
    CefRefPtr<GhosttiesDisplayHandler> display_handler_;
    CefRefPtr<GhosttiesLoadHandler> load_handler_;
    IMPLEMENT_REFCOUNTING(GhosttiesCefClient);
};

#endif // GHOSTTIES_CEF_AVAILABLE

#pragma mark - CEFBrowserView private interface

@interface CEFBrowserView () {
#if GHOSTTIES_CEF_AVAILABLE
    CefRefPtr<CefBrowser> _browser;
    CefRefPtr<GhosttiesCefClient> _client;
#endif
}

@property (nonatomic, readwrite) BOOL isLoading;
@property (nonatomic, readwrite) BOOL canGoBack;
@property (nonatomic, readwrite) BOOL canGoForward;
@property (nonatomic, readwrite, nullable) NSString *currentURL;
@property (nonatomic, readwrite, nullable) NSString *currentTitle;
@property (nonatomic) BOOL browserCreated;
@property (nonatomic, readwrite) BOOL isDevToolsOpen;

@end

#pragma mark - CEFBrowserView implementation

@implementation CEFBrowserView

- (instancetype)initWithFrame:(NSRect)frame url:(nullable NSString *)url {
    // Ensure non-zero frame — CEF's compositor aborts on zero-sized views.
    NSRect initialFrame = frame;
    if (initialFrame.size.width < 1) initialFrame.size.width = 800;
    if (initialFrame.size.height < 1) initialFrame.size.height = 600;

    self = [super initWithFrame:initialFrame];
    if (!self) return nil;

    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.wantsLayer = YES;
    self.browserCreated = NO;

#if GHOSTTIES_CEF_AVAILABLE
    [CEFBridgeManager initializeIfNeeded];
    if (![CEFBridgeManager isInitialized]) {
        return self;  // CEF failed to init — return stub view
    }

    _client = new GhosttiesCefClient(self);

    // Create browser immediately — Chromium's ProfileManager expects a browser
    // window shortly after CefInitialize or it shuts down the process.
    CefWindowInfo windowInfo;
    CefRect cefRect(0, 0, (int)initialFrame.size.width, (int)initialFrame.size.height);
    windowInfo.SetAsChild((__bridge CefWindowHandle)self, cefRect);

    CefBrowserSettings settings;
    NSString *urlStr = url ?: @"about:blank";
    CefString cefURL([urlStr UTF8String]);

    CefBrowserHost::CreateBrowser(windowInfo, _client, cefURL, settings,
                                  nullptr, nullptr);
    self.browserCreated = YES;
#else
    NSLog(@"[CEFBrowserView] CEF headers not available — running in stub mode.");
#endif

    return self;
}

- (void)dealloc {
#if GHOSTTIES_CEF_AVAILABLE
    if (_browser) {
        _browser->GetHost()->CloseBrowser(true);
        _browser = nullptr;
    }
    _client = nullptr;
#endif
}

#pragma mark - Navigation

- (void)loadURL:(NSString *)url {
#if GHOSTTIES_CEF_AVAILABLE
    if (!GhosttiesIsAllowedScheme(url)) {
        NSLog(@"[CEFBrowserView] Blocked loadURL with disallowed scheme: %@", url);
        return;
    }
    if (_browser && _browser->GetMainFrame()) {
        _browser->GetMainFrame()->LoadURL(CefString([url UTF8String]));
    }
#else
    NSLog(@"[CEFBrowserView] loadURL: stub — CEF not available");
#endif
}

- (void)goBack {
#if GHOSTTIES_CEF_AVAILABLE
    if (_browser) _browser->GoBack();
#else
    NSLog(@"[CEFBrowserView] goBack: stub — CEF not available");
#endif
}

- (void)goForward {
#if GHOSTTIES_CEF_AVAILABLE
    if (_browser) _browser->GoForward();
#else
    NSLog(@"[CEFBrowserView] goForward: stub — CEF not available");
#endif
}

- (void)reload {
#if GHOSTTIES_CEF_AVAILABLE
    if (_browser) _browser->Reload();
#else
    NSLog(@"[CEFBrowserView] reload: stub — CEF not available");
#endif
}

- (void)stopLoading {
#if GHOSTTIES_CEF_AVAILABLE
    if (_browser) _browser->StopLoad();
#else
    NSLog(@"[CEFBrowserView] stopLoading: stub — CEF not available");
#endif
}

#pragma mark - DevTools

- (void)showInlineDevTools:(NSView *)parentView {
#if GHOSTTIES_CEF_AVAILABLE
    if (!_browser) return;

    NSRect parentBounds = parentView.bounds;
    if (parentBounds.size.width < 1) parentBounds.size.width = 400;
    if (parentBounds.size.height < 1) parentBounds.size.height = 200;

    CefWindowInfo devToolsWindowInfo;
    CefRect cefRect(0, 0,
                    (int)parentBounds.size.width,
                    (int)parentBounds.size.height);
    devToolsWindowInfo.SetAsChild((__bridge CefWindowHandle)parentView, cefRect);

    CefBrowserSettings devToolsSettings;
    CefPoint inspectPoint;

    _browser->GetHost()->ShowDevTools(devToolsWindowInfo, _client,
                                      devToolsSettings, inspectPoint);
    self.isDevToolsOpen = YES;
#else
    NSLog(@"[CEFBrowserView] showInlineDevTools: stub — CEF not available");
#endif
}

- (void)closeDevTools {
#if GHOSTTIES_CEF_AVAILABLE
    if (_browser) {
        _browser->GetHost()->CloseDevTools();
        self.isDevToolsOpen = NO;
    }
#else
    NSLog(@"[CEFBrowserView] closeDevTools: stub — CEF not available");
#endif
}

#pragma mark - Lifecycle

- (void)closeBrowser {
#if GHOSTTIES_CEF_AVAILABLE
    if (_browser) {
        _browser->GetHost()->CloseBrowser(true);
        // _browser is nilled in OnBeforeClose callback
    }
#else
    NSLog(@"[CEFBrowserView] closeBrowser: stub — CEF not available");
#endif
}

#pragma mark - Layout

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
#if GHOSTTIES_CEF_AVAILABLE
    [self _syncCefChildBounds];
#endif
}

- (void)layout {
    [super layout];
}

/// Resize CEF's internal child view to match our bounds and notify the compositor.
- (void)_syncCefChildBounds {
#if GHOSTTIES_CEF_AVAILABLE
    // CEF inserts its own NSView as a child. It doesn't auto-resize with us,
    // so we must explicitly set its frame to fill our bounds.
    BOOL boundsChanged = NO;
    for (NSView *child in self.subviews) {
        if (child != self && ![child isKindOfClass:[NSTextField class]]) {
            if (!NSEqualRects(child.frame, self.bounds)) {
                child.frame = self.bounds;
                boundsChanged = YES;
            }
        }
    }
    if (boundsChanged && _browser) {
        _browser->GetHost()->WasResized();
    }
#endif
}

- (void)viewDidEndLiveResize {
    [super viewDidEndLiveResize];
#if GHOSTTIES_CEF_AVAILABLE
    // Final notification after the user finishes dragging the window edge.
    // Guarantees the compositor settles on the correct size even if
    // intermediate WasResized() calls were coalesced during the drag.
    if (_browser) {
        _browser->GetHost()->WasResized();
    }
#endif
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
#if GHOSTTIES_CEF_AVAILABLE
    if (_browser && self.window) {
        _browser->GetHost()->WasResized();
    }
#endif
}

#pragma mark - Internal callbacks (called from C++ handlers)

- (void)_didChangeURL:(NSString *)url {
    self.currentURL = url;
    if ([self.delegate respondsToSelector:@selector(browserView:didChangeURL:)]) {
        [self.delegate browserView:self didChangeURL:url];
    }
}

- (void)_didChangeTitle:(NSString *)title {
    self.currentTitle = title;
    if ([self.delegate respondsToSelector:@selector(browserView:didChangeTitle:)]) {
        [self.delegate browserView:self didChangeTitle:title];
    }
}

- (void)_didChangeLoadingState:(BOOL)loading
                      canGoBack:(BOOL)back
                   canGoForward:(BOOL)forward {
    self.isLoading = loading;
    self.canGoBack = back;
    self.canGoForward = forward;
    if ([self.delegate respondsToSelector:
             @selector(browserView:didChangeLoadingState:canGoBack:canGoForward:)]) {
        [self.delegate browserView:self didChangeLoadingState:loading
                         canGoBack:back canGoForward:forward];
    }
}

#if GHOSTTIES_CEF_AVAILABLE
- (void)_browserDidCreate:(CefRefPtr<CefBrowser>)browser {
    _browser = browser;
    // Sync CEF's internal child view and compositor to our current bounds.
    [self _syncCefChildBounds];
}

- (void)_browserDidClose {
    _browser = nullptr;
}
#endif

@end
