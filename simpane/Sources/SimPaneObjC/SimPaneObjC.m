#import "SimPaneObjC.h"
#import <objc/runtime.h>

NSString *const SPObjCErrorDomain = @"SimPaneObjC";

static NSError *ErrorFromException(NSException *e) {
    return [NSError errorWithDomain:SPObjCErrorDomain
                               code:1
                           userInfo:@{
                               NSLocalizedDescriptionKey: e.reason ?: @"objc exception",
                               @"name": e.name ?: @"?",
                           }];
}

static NSError *SimpleError(NSString *message) {
    return [NSError errorWithDomain:SPObjCErrorDomain
                               code:2
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// Skips the type qualifiers (const, in, out, byref, oneway, ...) that can prefix
/// an encoding so callers only ever switch on the base type character.
static const char *SkipQualifiers(const char *t) {
    while (*t == 'r' || *t == 'n' || *t == 'N' || *t == 'o' || *t == 'O' ||
           *t == 'R' || *t == 'V' || *t == 'A') {
        t++;
    }
    return t;
}

@implementation SPObjC

+ (nullable id)catching:(id _Nullable (^)(void))block error:(NSError **)error {
    @try {
        return block();
    } @catch (NSException *e) {
        if (error) *error = ErrorFromException(e);
        return nil;
    }
}

+ (BOOL)catchingVoid:(void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (error) *error = ErrorFromException(e);
        return NO;
    }
}

+ (nullable NSString *)typeEncodingFor:(SEL)sel on:(id)target {
    if (target == nil || sel == NULL) return nil;
    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (sig == nil) return nil;
        NSMutableString *s = [NSMutableString stringWithFormat:@"%s", sig.methodReturnType];
        [s appendString:@" <-"];
        for (NSUInteger i = 0; i < sig.numberOfArguments; i++) {
            [s appendFormat:@" %s", [sig getArgumentTypeAtIndex:i]];
        }
        return s;
    } @catch (NSException *e) {
        return nil;
    }
}

+ (nullable id)send:(SEL)sel to:(id)target args:(NSArray *)args error:(NSError **)error {
    return [self invoke:sel on:target objectArgs:args appendNilErrorPointer:NO error:error];
}

+ (nullable id)send:(SEL)sel to:(id)target argsPlusNilError:(NSArray *)args error:(NSError **)error {
    return [self invoke:sel on:target objectArgs:args appendNilErrorPointer:YES error:error];
}

+ (nullable id)invoke:(SEL)sel
                   on:(id)target
           objectArgs:(NSArray *)args
appendNilErrorPointer:(BOOL)appendError
                error:(NSError **)error {
    if (target == nil) {
        if (error) *error = SimpleError(@"nil target");
        return nil;
    }
    __block id result = nil;
    __block NSError *inner = nil;

    @try {
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (sig == nil) {
            if (error) *error = SimpleError([NSString stringWithFormat:@"no method signature for %@",
                                                                      NSStringFromSelector(sel)]);
            return nil;
        }

        NSUInteger supplied = args.count + (appendError ? 1 : 0);
        if (sig.numberOfArguments != supplied + 2) {
            if (error) *error = SimpleError([NSString
                stringWithFormat:@"%@ takes %lu args, %lu supplied", NSStringFromSelector(sel),
                                 (unsigned long)(sig.numberOfArguments - 2), (unsigned long)supplied]);
            return nil;
        }

        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.selector = sel;
        inv.target = target;

        for (NSUInteger i = 0; i < args.count; i++) {
            id a = args[i];
            if (a == [NSNull null]) a = nil;
            [inv setArgument:&a atIndex:i + 2];
        }
        if (appendError) {
            NSError *__autoreleasing *nullErr = NULL;
            [inv setArgument:&nullErr atIndex:args.count + 2];
        }

        [inv invoke];

        const char *rt = SkipQualifiers(sig.methodReturnType);
        NSUInteger len = sig.methodReturnLength;

        switch (rt[0]) {
        case 'v':
            result = nil;
            break;
        case '@': {
            // Getters return +0; retain into a strong local before the pool drains.
            __unsafe_unretained id raw = nil;
            [inv getReturnValue:&raw];
            result = raw;
            break;
        }
        case '#': {
            Class c = Nil;
            [inv getReturnValue:&c];
            result = c ? NSStringFromClass(c) : nil;
            break;
        }
        case ':': {
            SEL s = NULL;
            [inv getReturnValue:&s];
            result = s ? NSStringFromSelector(s) : nil;
            break;
        }
        case 'B':
        case 'c': {
            char v = 0;
            [inv getReturnValue:&v];
            result = @(v);
            break;
        }
        case 'C': { unsigned char v = 0; [inv getReturnValue:&v]; result = @(v); break; }
        case 's': { short v = 0; [inv getReturnValue:&v]; result = @(v); break; }
        case 'S': { unsigned short v = 0; [inv getReturnValue:&v]; result = @(v); break; }
        case 'i': { int v = 0; [inv getReturnValue:&v]; result = @(v); break; }
        case 'I': { unsigned int v = 0; [inv getReturnValue:&v]; result = @(v); break; }
        case 'l': { long v = 0; [inv getReturnValue:&v]; result = @(v); break; }
        case 'L': { unsigned long v = 0; [inv getReturnValue:&v]; result = @(v); break; }
        case 'q': { long long v = 0; [inv getReturnValue:&v]; result = @(v); break; }
        case 'Q': { unsigned long long v = 0; [inv getReturnValue:&v]; result = @(v); break; }
        case 'f': { float v = 0; [inv getReturnValue:&v]; result = @(v); break; }
        case 'd': { double v = 0; [inv getReturnValue:&v]; result = @(v); break; }
        case '^': {
            void *v = NULL;
            [inv getReturnValue:&v];
            // Opaque pointers (IOSurfaceRef included) come back as a boxed address
            // so Swift can bridge them without the compiler knowing the type.
            result = [NSValue valueWithPointer:v];
            break;
        }
        default: {
            if (len == 0) { result = nil; break; }
            void *buf = calloc(1, len);
            [inv getReturnValue:buf];
            result = [NSValue valueWithBytes:buf objCType:rt];
            free(buf);
            break;
        }
        }
    } @catch (NSException *e) {
        inner = ErrorFromException(e);
    }

    if (inner) {
        if (error) *error = inner;
        return nil;
    }
    return result;
}

+ (NSArray<NSString *> *)protocolNamesOf:(id)target {
    NSMutableOrderedSet<NSString *> *out = [NSMutableOrderedSet orderedSet];
    if (target == nil) return out.array;

    @try {
        // Static conformance declared on the class chain.
        for (Class c = object_getClass(target); c != Nil; c = class_getSuperclass(c)) {
            unsigned int n = 0;
            Protocol *__unsafe_unretained *list = class_copyProtocolList(c, &n);
            for (unsigned int i = 0; i < n; i++) {
                [out addObject:@(protocol_getName(list[i]))];
            }
            if (list) free(list);
        }

        // ROCK proxies additionally carry the remote object's protocol set.
        SEL protocolsSel = NSSelectorFromString(@"protocols");
        if ([target methodSignatureForSelector:protocolsSel] != nil) {
            // Selector is known-good and is a plain getter, so there is no
            // ownership subtlety for ARC to worry about here.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id dynamic = [target performSelector:protocolsSel];
#pragma clang diagnostic pop
            if ([dynamic respondsToSelector:@selector(objectEnumerator)]) {
                for (id p in dynamic) {
                    if ([p isKindOfClass:NSString.class]) {
                        [out addObject:p];
                    } else if (p) {
                        [out addObject:@(protocol_getName((Protocol *)p))];
                    }
                }
            }
        }
    } @catch (NSException *e) {
        // Partial results beat none.
    }

    return out.array;
}

@end
