#import "ObjCExceptionCatcher.h"

#import <AppKit/AppKit.h>

BOOL GhosttyAddTabbedWindowSafely(
    id parent,
    id child,
    NSInteger ordered,
    NSError * _Nullable * _Nullable error
) {
    // AppKit occasionally throws NSException while adding tabbed windows,
    // in particular when creating tabs from the tab overview page since some
    // macOS update recently in 2025/2026 (unclear).
    //
    // We must catch it in Objective-C; letting this cross into Swift is unsafe.
    @try {
        [((NSWindow *)parent) addTabbedWindow:(NSWindow *)child ordered:(NSWindowOrderingMode)ordered];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: @"Unknown Objective-C exception";
            *error = [NSError errorWithDomain:@"Ghostty.ObjCException"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: reason,
                                         @"exception_name": exception.name,
                                     }];
        }

        return NO;
    }
}
