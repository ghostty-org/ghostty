#import "CEFBridge.h"
#import <AppKit/AppKit.h>

// CEF headers are only available after the framework is downloaded.
// When absent, all methods operate in stub mode and log a warning.
#if __has_include("include/cef_app.h")
#define CEF_AVAILABLE 1
#import "include/cef_app.h"
#import "include/cef_browser.h"
#import "include/cef_command_line.h"
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

    // CEF's own log file (for diagnosing subprocess issues).
    CefString(&settings.log_file) = "/tmp/ghostties-cef-internal.log";
    settings.log_severity = LOGSEVERITY_INFO;

    settings.remote_debugging_port = 0;

    // ---- Main args (with Chromium switches) ----------------------------
    // Pass --use-mock-keychain to suppress the macOS Keychain password
    // prompt that crashes ad-hoc signed apps.

    static const char *fakeArgv[] = {
        "Ghostties",
        "--use-mock-keychain",
        nullptr
    };
    CefMainArgs mainArgs(2, const_cast<char**>(fakeArgv));

    CefRefPtr<CefApp> cefApp = nullptr;
    bool success = CefInitialize(mainArgs, settings, cefApp, nullptr);
    if (!success) {
        NSLog(@"[CEFBridge] CefInitialize failed.");
        return;
    }

    _remoteDebuggingPort = settings.remote_debugging_port;

    // ---- Message loop timer (60 Hz) ------------------------------------
    // Pumps CEF's event loop. Must run before CreateBrowser so helpers can
    // establish IPC with the main process.

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

+ (void)startMessageLoopIfNeeded {
    if (_messageLoopTimer) return;
    if (!_isInitialized) return;

    _messageLoopTimer = [NSTimer timerWithTimeInterval:(1.0 / 60.0)
                                                target:self
                                              selector:@selector(_messageLoopTick:)
                                              userInfo:nil
                                               repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_messageLoopTimer
                              forMode:NSRunLoopCommonModes];
    NSLog(@"[CEFBridge] Message loop started.");
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
