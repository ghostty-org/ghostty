#import <QuartzCore/QuartzCore.h>

typedef NS_ENUM(NSUInteger, VibrantLayerType) {
    VibrantLayerTypeLight,
    VibrantLayerTypeDark
};

// This layer can be used to recreate the "vibrant" appearance you see of
// views placed inside `NSVisualEffectView`s. When a light NSAppearance is
// active, we will use the private "plus darker" blend mode. For dark
// appearances we use "plus lighter".
@interface VibrantLayer : CALayer

- (id)initForAppearance:(VibrantLayerType)type;

@end
