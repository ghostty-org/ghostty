#import "VibrantLayer.h"

@interface VibrantLayer()

@property (nonatomic) VibrantLayerType type;

@end

@implementation VibrantLayer

- (id)initForAppearance:(VibrantLayerType)type {
    self = [super init];
    if (self) {
        _type = type;
    }
    return self;
}

- (id)compositingFilter {
    if (self.type == VibrantLayerTypeLight) {
        return @"plusD";
    } else {
        return @"plusL";
    }
}

@end
