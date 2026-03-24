#import "CEFBrowserView.h"
#import "CEFBridge.h"

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

@end

#pragma mark - CEFBrowserView implementation

@implementation CEFBrowserView

- (instancetype)initWithFrame:(NSRect)frame url:(nullable NSString *)url {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.wantsLayer = YES;

#if GHOSTTIES_CEF_AVAILABLE
    // Lazy-init the CEF runtime on first browser creation.
    [CEFBridgeManager initializeIfNeeded];

    _client = new GhosttiesCefClient(self);

    CefWindowInfo windowInfo;
    windowInfo.SetAsChild((__bridge CefWindowHandle)self, 0, 0,
                          (int)frame.size.width, (int)frame.size.height);

    CefBrowserSettings settings;

    CefString cefURL;
    if (url.length > 0) {
        cefURL = CefString([url UTF8String]);
    } else {
        cefURL = CefString("about:blank");
    }

    CefBrowserHost::CreateBrowser(windowInfo, _client, cefURL, settings,
                                  nullptr, nullptr);
#else
    NSLog(@"[CEFBrowserView] CEF headers not available — running in stub mode. "
          @"Run scripts/download-cef.sh to enable the embedded browser.");
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

- (void)showDevTools {
#if GHOSTTIES_CEF_AVAILABLE
    if (!_browser) return;

    CefWindowInfo devToolsWindowInfo;
    devToolsWindowInfo.SetAsPopup(nullptr, "DevTools");

    CefBrowserSettings devToolsSettings;
    CefPoint inspectPoint;

    _browser->GetHost()->ShowDevTools(devToolsWindowInfo, _client,
                                      devToolsSettings, inspectPoint);
#else
    NSLog(@"[CEFBrowserView] showDevTools: stub — CEF not available");
#endif
}

- (void)closeDevTools {
#if GHOSTTIES_CEF_AVAILABLE
    if (_browser) _browser->GetHost()->CloseDevTools();
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
}

- (void)_browserDidClose {
    _browser = nullptr;
}
#endif

@end
