#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Manages CEF lifecycle — lazy initialization, message loop, and shutdown.
/// Thread safety: all methods must be called on the main thread.
@interface CEFBridgeManager : NSObject

/// Whether CEF has been initialized.
@property (class, nonatomic, readonly) BOOL isInitialized;

/// Initialize CEF if not already done. Called lazily on first browser creation.
/// Must be called on the main thread.
+ (void)initializeIfNeeded;

/// Start the 60Hz message loop timer. Called after the first browser is created.
/// Safe to call multiple times — only creates the timer once.
+ (void)startMessageLoopIfNeeded;

/// Shut down CEF. Must close all browsers first.
/// Called automatically on app termination.
+ (void)shutdown;

/// The port assigned for remote debugging (0 if not initialized).
@property (class, nonatomic, readonly) int remoteDebuggingPort;

@end

NS_ASSUME_NONNULL_END
