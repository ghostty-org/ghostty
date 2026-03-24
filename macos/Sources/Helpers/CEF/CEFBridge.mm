#import "CEFBridge.h"

// CEF headers are only available after the framework is downloaded.
// When absent, all methods operate in stub mode and log a warning.
#if __has_include("include/cef_app.h")
#define CEF_AVAILABLE 1
#import "include/cef_app.h"
#import "include/cef_browser.h"
#import "include/wrapper/cef_helpers.h"
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
    // ---- Framework paths ------------------------------------------------

    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *frameworkPath = [mainBundle.privateFrameworksPath
        stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
    NSString *helperPath = [[mainBundle.bundlePath
        stringByAppendingPathComponent:@"Contents/Helpers/Ghostties Helper.app/Contents/MacOS/Ghostties Helper"]
        stringByStandardizingPath];

    // ---- CefSettings ----------------------------------------------------

    CefSettings settings;
    settings.no_sandbox = true;

    CefString(&settings.framework_dir_path).FromNSString(frameworkPath);
    CefString(&settings.browser_subprocess_path).FromNSString(helperPath);

    // Auto-assign a free port for remote debugging.
    settings.remote_debugging_port = 0;
    settings.log_severity = LOGSEVERITY_WARNING;

    // ---- Main args ------------------------------------------------------

    CefMainArgs mainArgs(0, nullptr);

    // ---- Initialize -----------------------------------------------------

    CefRefPtr<CefApp> cefApp = nullptr;
    bool success = CefInitialize(mainArgs, settings, cefApp, nullptr);
    if (!success) {
        NSLog(@"[CEFBridge] CefInitialize failed.");
        return;
    }

    _remoteDebuggingPort = settings.remote_debugging_port;

    // ---- Message loop timer (60 Hz) ------------------------------------

    _messageLoopTimer = [NSTimer timerWithTimeInterval:(1.0 / 60.0)
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
    // Stub mode — CEF framework not present.
    NSLog(@"[CEFBridge] CEF headers not available — running in stub mode.");
#endif
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
