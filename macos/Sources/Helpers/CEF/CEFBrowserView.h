#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class CEFBrowserView;

@protocol CEFBrowserViewDelegate <NSObject>
@optional
- (void)browserView:(CEFBrowserView *)view didChangeURL:(NSString *)url;
- (void)browserView:(CEFBrowserView *)view didChangeTitle:(NSString *)title;
- (void)browserView:(CEFBrowserView *)view didChangeLoadingState:(BOOL)isLoading
         canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
@end

/// Hosts a single CEF browser instance as an NSView.
/// Each instance is a separate Chromium renderer process.
@interface CEFBrowserView : NSView

@property (nonatomic, weak, nullable) id<CEFBrowserViewDelegate> delegate;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly, nullable) NSString *currentURL;
@property (nonatomic, readonly, nullable) NSString *currentTitle;
@property (nonatomic, readonly) BOOL isDevToolsOpen;

- (instancetype)initWithFrame:(NSRect)frame url:(nullable NSString *)url;
- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
/// Open DevTools inline inside the given parent view.
- (void)showInlineDevTools:(NSView *)parentView;
/// Close DevTools (works for both popup and inline).
- (void)closeDevTools;
- (void)closeBrowser;

@end

NS_ASSUME_NONNULL_END
