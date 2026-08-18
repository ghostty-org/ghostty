//  Objective-C dispatch helpers for talking to CoreSimulator / SimulatorKit.
//
//  Two things Swift cannot do on its own and that this glue exists to provide:
//
//  1. Catch ObjC exceptions. Private frameworks raise them freely, and an
//     uncaught NSException aborts the process.
//  2. Invoke arbitrary selectors on CoreSimulator's ROCK XPC proxies. Those
//     proxies are not plain objects: KVC raises, -respondsToSelector: answers
//     optimistically, and class introspection only shows the proxy machinery.
//     -methodSignatureForSelector: performs a real remote lookup, so NSInvocation
//     built from it is the only reliable path.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const SPObjCErrorDomain;

@interface SPObjC : NSObject

/// Runs `block` inside @try/@catch, converting any NSException into an NSError.
+ (nullable id)catching:(id _Nullable (^)(void))block
                  error:(NSError *_Nullable *_Nullable)error;

/// Void-returning variant. The `catching:` form cannot express "succeeded and
/// returned nil": a nil return with no error reads as a failure once bridged
/// into Swift's throwing convention.
+ (BOOL)catchingVoid:(void (^)(void))block
               error:(NSError *_Nullable *_Nullable)error;

/// Sends `sel` to `target` with the given object arguments (use NSNull for a nil
/// argument), boxing scalar and struct returns. Works on ROCK proxies.
+ (nullable id)send:(SEL)sel
                 to:(id)target
               args:(nullable NSArray *)args
              error:(NSError *_Nullable *_Nullable)error;

/// Like -send:to:args:error: but appends a NULL `NSError **` out-parameter, which
/// is the shape of most CoreSimulator methods.
+ (nullable id)send:(SEL)sel
                 to:(id)target
   argsPlusNilError:(nullable NSArray *)args
              error:(NSError *_Nullable *_Nullable)error;

/// The selector's ObjC type encoding, or nil when the target genuinely has no
/// such method. This is the trustworthy existence test — unlike
/// -respondsToSelector:, which ROCK proxies over-report.
+ (nullable NSString *)typeEncodingFor:(SEL)sel on:(id)target;

/// Protocol names the object conforms to, including the dynamic set a ROCK proxy
/// reports through its own `protocols` property.
+ (NSArray<NSString *> *)protocolNamesOf:(id)target;

@end

NS_ASSUME_NONNULL_END
