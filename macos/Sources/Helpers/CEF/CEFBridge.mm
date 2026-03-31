#import "CEFBridge.h"
#import <AppKit/AppKit.h>
#include <atomic>

#if __has_include("include/cef_app.h")
#define CEF_AVAILABLE 1
#import "include/cef_app.h"
#import "include/cef_browser.h"
#import "include/cef_browser_process_handler.h"
#import "include/wrapper/cef_helpers.h"
#import "include/wrapper/cef_library_loader.h"
#else
#define CEF_AVAILABLE 0
#endif

// ---------------------------------------------------------------------------
// Static state
// ---------------------------------------------------------------------------

static BOOL _isInitialized = NO;
static int _remoteDebuggingPort = 0;
static NSTimer *_messageLoopTimer = nil;

// ---------------------------------------------------------------------------
// CefApp implementation for external message pump integration
// ---------------------------------------------------------------------------

#if CEF_AVAILABLE

/// Handles scheduling of message pump work from CEF's internal threads.
/// When CEF needs processing time, it calls OnScheduleMessagePumpWork
/// which dispatches to the main thread for our timer to handle.
class GhosttiesBrowserProcessHandler : public CefBrowserProcessHandler {
public:
    void OnScheduleMessagePumpWork(int64_t delay_ms) override {
        // Coalesce rapid zero-delay callbacks to avoid flooding the main queue
        // (CefDoMessageLoopWork can re-schedule with delay=0, creating a spin loop
        // that starves AppKit and causes the beach ball).
        if (delay_ms <= 0) {
            if (!work_pending_.exchange(true)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    work_pending_ = false;
                    CefDoMessageLoopWork();
                });
            }
        } else {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, delay_ms * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{
                    CefDoMessageLoopWork();
                });
        }
    }

private:
    std::atomic<bool> work_pending_{false};
    IMPLEMENT_REFCOUNTING(GhosttiesBrowserProcessHandler);
};

class GhosttiesApp : public CefApp {
public:
    GhosttiesApp() : browser_handler_(new GhosttiesBrowserProcessHandler()) {}

    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
        return browser_handler_;
    }

private:
    CefRefPtr<GhosttiesBrowserProcessHandler> browser_handler_;
    IMPLEMENT_REFCOUNTING(GhosttiesApp);
};

#endif // CEF_AVAILABLE

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

@interface CEFBridgeManager ()
+ (void)_messageLoopTick:(NSTimer *)timer;
+ (void)_appWillTerminate:(NSNotification *)note;
@end

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

@implementation CEFBridgeManager

#pragma mark - Properties

+ (BOOL)isInitialized {
    return _isInitialized;
}

+ (int)remoteDebuggingPort {
    return _remoteDebuggingPort;
}

#pragma mark - Lifecycle

+ (void)initializeIfNeeded {
    if (_isInitialized) return;

    NSAssert([NSThread isMainThread],
             @"CEFBridgeManager.initializeIfNeeded must be called on the main thread");

#if CEF_AVAILABLE
    // ---- Load framework dynamically ------------------------------------
    static CefScopedLibraryLoader sLibraryLoader;
    static BOOL sLibraryLoaded = NO;
    if (!sLibraryLoaded) {
        if (!sLibraryLoader.LoadInMain()) {
            NSLog(@"[CEFBridge] Failed to load CEF framework.");
            return;
        }
        sLibraryLoaded = YES;
    }

    // ---- Framework paths ------------------------------------------------

    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *frameworkPath = [mainBundle.privateFrameworksPath
        stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
    NSString *helperPath = [[mainBundle.privateFrameworksPath
        stringByAppendingPathComponent:@"Ghostties Helper.app/Contents/MacOS/Ghostties Helper"]
        stringByStandardizingPath];

    // ---- CefSettings ----------------------------------------------------

    CefSettings settings;
    settings.no_sandbox = true;
    settings.external_message_pump = true;

    CefString(&settings.framework_dir_path) = [frameworkPath UTF8String];
    CefString(&settings.browser_subprocess_path) = [helperPath UTF8String];

    // Cache directory — required by CEF for subprocess data exchange.
    NSString *cacheDir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"ghostties-cef"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    CefString(&settings.root_cache_path) = [cacheDir UTF8String];
    CefString(&settings.cache_path) = [cacheDir UTF8String];
    CefString(&settings.locale) = "en-US";

    // CEF's own log file.
    CefString(&settings.log_file) = "/tmp/ghostties-cef-internal.log";
    settings.log_severity = LOGSEVERITY_WARNING;

    settings.remote_debugging_port = 0;

    // ---- Main args ------------------------------------------------------

    static const char *fakeArgv[] = {
        "Ghostties",
        "--use-mock-keychain",
        nullptr
    };
    CefMainArgs mainArgs(2, const_cast<char**>(fakeArgv));

    // ---- Initialize with our CefApp ------------------------------------
    // GhosttiesApp provides the BrowserProcessHandler which implements
    // OnScheduleMessagePumpWork for external_message_pump integration.

    CefRefPtr<GhosttiesApp> app(new GhosttiesApp());
    bool success = CefInitialize(mainArgs, settings, app, nullptr);
    if (!success) {
        NSLog(@"[CEFBridge] CefInitialize failed.");
        return;
    }

    _remoteDebuggingPort = settings.remote_debugging_port;

    // ---- Backup timer (4 Hz) -------------------------------------------
    // The primary message pump is driven by OnScheduleMessagePumpWork above.
    // This low-frequency timer is a safety net to ensure events are processed
    // even if a callback is missed.

    _messageLoopTimer = [NSTimer timerWithTimeInterval:0.25
                                                target:self
                                              selector:@selector(_messageLoopTick:)
                                              userInfo:nil
                                               repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_messageLoopTimer
                              forMode:NSRunLoopCommonModes];

    // ---- App termination observer --------------------------------------

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_appWillTerminate:)
                                                 name:NSApplicationWillTerminateNotification
                                               object:nil];

    _isInitialized = YES;
    NSLog(@"[CEFBridge] CEF initialized (debug port: %d).", _remoteDebuggingPort);

#else
    NSLog(@"[CEFBridge] CEF headers not available — running in stub mode.");
#endif
}

+ (void)startMessageLoopIfNeeded {
    // With external_message_pump, the pump is driven by OnScheduleMessagePumpWork.
    // This is a no-op but kept for API compatibility.
}

+ (void)shutdown {
    if (!_isInitialized) return;

    NSAssert([NSThread isMainThread],
             @"CEFBridgeManager.shutdown must be called on the main thread");

    [_messageLoopTimer invalidate];
    _messageLoopTimer = nil;

#if CEF_AVAILABLE
    CefShutdown();
    NSLog(@"[CEFBridge] CEF shut down.");
#endif

    _isInitialized = NO;
    _remoteDebuggingPort = 0;
}

#pragma mark - Private

+ (void)_messageLoopTick:(NSTimer *)timer {
#if CEF_AVAILABLE
    CefDoMessageLoopWork();
#endif
}

+ (void)_appWillTerminate:(NSNotification *)note {
    [self shutdown];
}

@end
