#import "Core.h"
#import "UserPreferences.h"
#import <math.h>

static void PlaybackChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                            const void *object, CFDictionaryRef userInfo) {
    Core *core = (__bridge Core *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [core editCurrentState];
        [core core];
    });
}

@interface Core ()
@property (nonatomic, strong) NSTimer *stateRefreshTimer;
@end

@implementation Core
+ (instancetype)sharedInstance {
    static Core *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [self new];
        shared.pathToState = @"/var/mobile/Library/Preferences/com.kainograze.iPresence-Springboard-Helper.plist";
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)shared,
            PlaybackChanged, CFSTR("com.kainograze.iPresence-Springboard-Helper.State-Changed"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        [NSNotificationCenter.defaultCenter addObserver:shared selector:@selector(settingsChanged:) name:@"settingsChanged" object:nil];
    });
    return shared;
}

- (void)start {
    [self editCurrentState];
    [self core];
    if (self.stateRefreshTimer) return;
    __weak typeof(self) weakSelf = self;
    // Recover missed Darwin notifications and stop a stale presence after SpringBoard exits.
    self.stateRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) {
        [weakSelf editCurrentState];
        [weakSelf core];
    }];
    self.stateRefreshTimer.tolerance = 3;
}

- (void)editCurrentState {
    id state = [NSDictionary dictionaryWithContentsOfFile:self.pathToState][@"currentState"];
    NSDictionary *valid = [state isKindOfClass:NSDictionary.class] ? state : nil;
    id updatedAt = valid[@"updatedAt"];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval timestamp = [updatedAt isKindOfClass:NSNumber.class] ? [updatedAt doubleValue] : 0;
    BOOL fresh = isfinite(timestamp) && timestamp > 0 && now - timestamp <= 120 && timestamp - now <= 30;
    if (!fresh) {
        self.currentState = @{@"musicIsPlaying": @NO, @"metadata": @{}};
        return;
    }
    id playing = valid[@"musicIsPlaying"];
    self.currentState = @{
        @"musicIsPlaying": @([playing isKindOfClass:NSNumber.class] && [playing boolValue]),
        @"metadata": [valid[@"metadata"] isKindOfClass:NSDictionary.class] ? valid[@"metadata"] : @{}
    };
}

- (void)core {
    if (![UserPreferences.sharedInstance valOfShowAsDiscordStatus] || ![UserPreferences.sharedInstance valOfLinkedAccount]) {
        [self setAsleep];
        return;
    }
    self.musicIsPlaying = [self.currentState[@"musicIsPlaying"] boolValue];
    // Cache the latest state before the Social SDK can become ready.
    [NSNotificationCenter.defaultCenter postNotificationName:@"playbackStateChanged" object:self userInfo:self.currentState];
    if (self.musicIsPlaying) [self setAwake];
    else if (self.isAwake) [self setAsleepTimer];
}

- (void)setAsleepTimer {
    // A stream of paused-state refreshes must not postpone the five-minute idle deadline.
    if (self.asleepTimer || !self.isAwake) return;
    __weak typeof(self) weakSelf = self;
    self.asleepTimer = [NSTimer scheduledTimerWithTimeInterval:300 repeats:NO block:^(NSTimer *timer) {
        [weakSelf setAsleep];
    }];
}

- (void)invalidateSetAsleepTimer {
    [self.asleepTimer invalidate];
    self.asleepTimer = nil;
}

- (void)setAwake {
    [self invalidateSetAsleepTimer];
    if (self.isAwake) return;
    self.isAwake = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:@"awake" object:self];
}

- (void)setAsleep {
    [self invalidateSetAsleepTimer];
    if (!self.isAwake) return;
    self.isAwake = NO;
    [NSNotificationCenter.defaultCenter postNotificationName:@"sleep" object:self];
}

- (void)settingsChanged:(NSNotification *)notification {
    [self setAsleep];
    // Finish resetting the credential/session before core can publish the next awake event.
    [NSNotificationCenter.defaultCenter postNotificationName:@"resetConnection" object:self];
    [self editCurrentState];
    [self core];
}
@end
