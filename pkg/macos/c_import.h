// All of our C imports consolidated into one place. We used to
// import them one by one in each package but Zig 0.14 has some
// kind of issue with that I wasn't able to minimize.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <CoreVideo/CoreVideo.h>
#include <CoreVideo/CVPixelBuffer.h>
#include <QuartzCore/CALayer.h>
#include <IOSurface/IOSurfaceRef.h>
#include <dispatch/dispatch.h>
#include <os/log.h>
#include <os/signpost.h>

#ifdef __APPLE__
#include <TargetConditionals.h>
#if TARGET_OS_MAC && !TARGET_OS_IPHONE
#include <Carbon/Carbon.h>
#endif
#endif
