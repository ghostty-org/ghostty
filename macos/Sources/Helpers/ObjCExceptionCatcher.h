#import <Foundation/Foundation.h>

/// This file contains wrappers around various ObjC functions so we can catch
/// exceptions, since you can't natively catch ObjC exceptions from Swift
/// (at least at the time of writing this comment).

/// NSWindow.addTabbedWindow wrapper
FOUNDATION_EXPORT BOOL GhosttyAddTabbedWindowSafely(
    id _Nonnull parent,
    id _Nonnull child,
    NSInteger ordered,
    NSError * _Nullable * _Nullable error
);

/// NSWindowController.showWindow wrapper
FOUNDATION_EXPORT BOOL GhosttyShowWindowSafely(
    id _Nonnull controller,
    id _Nullable sender,
    NSError * _Nullable * _Nullable error
);

/// NSWindow.makeKeyAndOrderFront wrapper
FOUNDATION_EXPORT BOOL GhosttyMakeKeyAndOrderFrontSafely(
    id _Nonnull window,
    id _Nullable sender,
    NSError * _Nullable * _Nullable error
);

/// NSUndoManager.undo wrapper
FOUNDATION_EXPORT BOOL GhosttyUndoSafely(
    id _Nonnull undoManager,
    NSError * _Nullable * _Nullable error
);

/// NSUndoManager.redo wrapper
FOUNDATION_EXPORT BOOL GhosttyRedoSafely(
    id _Nonnull undoManager,
    NSError * _Nullable * _Nullable error
);
