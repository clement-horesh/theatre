#import <Cocoa/Cocoa.h>
#import <Sparkle/Sparkle.h>
@interface SmokeDriver : NSObject <SPUUserDriver>
@property(copy) void (^onFound)(SUAppcastItem *);
@end
