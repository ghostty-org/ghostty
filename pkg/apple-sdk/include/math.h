#ifndef GHOSTTY_APPLE_SDK_MATH_H
#define GHOSTTY_APPLE_SDK_MATH_H

// Resume the header search after this compatibility directory so we include
// the selected Xcode SDK's math.h. A regular #include <math.h> would find this
// wrapper again and loop forever. This is a Clang extension but Zig uses
// Clang so we good.
#include_next <math.h>

// Xcode 27's math.h expects Clang's float.h to define these when requested
// with __need_infinity_nan. Zig 0.16's bundled float.h predates that protocol;
// remove these fallbacks once Zig's bundled Clang headers implement it.
#ifndef INFINITY
#define INFINITY (__builtin_inff())
#endif

#ifndef NAN
#define NAN (__builtin_nanf(""))
#endif

#endif
