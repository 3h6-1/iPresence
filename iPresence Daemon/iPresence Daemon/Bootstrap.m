// Original project by kainograze. Updated by 3h6_1.
#import "Bootstrap.h"

@implementation Bootstrap
+ (instancetype)sharedInstance {
    static Bootstrap *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}
- (void)start {
    [UserPreferences sharedInstance];
    [DCServerCommunicator.sharedInstance startCommunicator];
    [PresenceUpdater sharedInstance];
    [Core.sharedInstance start];
}
@end
