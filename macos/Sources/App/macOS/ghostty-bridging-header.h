// C imports here are exposed to Swift.

#import "VibrantLayer.h"

// SDK version check for macOS 26 features
#import <AvailabilityMacros.h>

// Check if SDK version is macOS 26 or higher
// macOS 26.0 would be 260000 in the version macro
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
    #define SUPPORTS_MACOS_26_FEATURES 1
#endif
