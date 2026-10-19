#import "UserPreferences.h"
#import "IPOAuthStore.h"

static void PreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                               const void *object, CFDictionaryRef userInfo) {
    UserPreferences *preferences = (__bridge UserPreferences *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [preferences settingsUpdated];
        [NSNotificationCenter.defaultCenter postNotificationName:@"settingsChanged" object:preferences];
    });
}

@implementation UserPreferences
+ (instancetype)sharedInstance {
    static UserPreferences *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [self new];
        // Mobile user data is outside the rootless bootstrap prefix.
        shared.pathToSettings = @"/var/mobile/Library/Preferences/com.kainograze.iPresence.plist";
        [shared settingsUpdated];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)shared,
            PreferencesChanged, CFSTR("com.kainograze.iPresence.settingsChanged"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    });
    return shared;
}

- (void)settingsUpdated {
    // App writes atomically. A missing/invalid file disables publishing safely, without blocking launchd.
    self.settings = [NSDictionary dictionaryWithContentsOfFile:self.pathToSettings] ?: @{};
}

- (BOOL)valOfLinkedAccount { return [IPOAuthStore credentials] != nil; }
- (BOOL)valOfShowAsDiscordStatus {
    id value = self.settings[@"showAsDiscordStatus"];
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}
- (BOOL)valOfDisplayIosVersion {
    id value = self.settings[@"displayIosVersion"];
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}
- (NSString *)valOfIosVersion {
    id version = self.settings[@"iosVersion"];
    return [version isKindOfClass:NSString.class] ? version : @"";
}
@end
