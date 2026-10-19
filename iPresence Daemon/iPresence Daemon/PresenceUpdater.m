#import "PresenceUpdater.h"
#import "UserPreferences.h"
#import <math.h>

@interface PresenceUpdater ()
@property (nonatomic) NSTimeInterval lastSendTime;
@property (nonatomic, copy) NSDictionary *lastActivity;
@property (nonatomic) BOOL sentPresence;
@end

@implementation PresenceUpdater
+ (instancetype)sharedInstance {
    static PresenceUpdater *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [self new];
        shared.state = PresenceUpdaterStateSleeping;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:shared selector:@selector(awake:) name:@"connected" object:nil];
        [center addObserver:shared selector:@selector(sleep:) name:@"sleep" object:nil];
        [center addObserver:shared selector:@selector(sleep:) name:@"idle" object:nil];
        [center addObserver:shared selector:@selector(sleep:) name:@"disconnected" object:nil];
        [center addObserver:shared selector:@selector(core:) name:@"playbackStateChanged" object:nil];
    });
    return shared;
}

- (void)core:(NSNotification *)notification {
    self.currentState = notification.userInfo;
    self.musicIsPlaying = [self.currentState[@"musicIsPlaying"] boolValue];
    [self jsonSender];
}

- (void)jsonSender {
    if (self.state != PresenceUpdaterStateConnected) return;
    NSDictionary *activity = self.musicIsPlaying ? [self generateValidActivityJson] : nil;
    if (self.sentPresence && ((!activity && !self.lastActivity) || [activity isEqualToDictionary:self.lastActivity])) return;
    NSTimeInterval remaining = self.lastSendTime + 5.5 - NSProcessInfo.processInfo.systemUptime;
    if (remaining > 0) {
        self.pendingUpdate = YES;
        if (!self.presenceCooldownTimer) {
            __weak typeof(self) weakSelf = self;
            self.presenceCooldownTimer = [NSTimer scheduledTimerWithTimeInterval:remaining repeats:NO block:^(NSTimer *timer) {
                weakSelf.presenceCooldownTimer = nil;
                [weakSelf jsonSender];
            }];
        }
        return;
    }
    self.pendingUpdate = NO;
    self.lastSendTime = NSProcessInfo.processInfo.systemUptime;
    self.lastActivity = activity;
    self.sentPresence = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:@"sendActivityJson" object:self userInfo:activity];
}

- (NSString *)metadataString:(id)value fallback:(NSString *)fallback {
    return [value isKindOfClass:NSString.class] && [value length] ? value : fallback;
}

- (NSDictionary *)generateValidActivityJson {
    NSDictionary *metadata = [self.currentState[@"metadata"] isKindOfClass:NSDictionary.class] ? self.currentState[@"metadata"] : @{};
    NSString *artist = [self metadataString:metadata[@"artist"] fallback:@"Unknown Artist"];
    NSString *title = [self metadataString:metadata[@"title"] fallback:@"Unknown Song"];
    NSString *album = [self metadataString:metadata[@"album"] fallback:@"Unknown Album"];
    NSString *version = [UserPreferences.sharedInstance valOfIosVersion];
    NSString *text = [UserPreferences.sharedInstance valOfDisplayIosVersion] && version.length ?
        [NSString stringWithFormat:@"on iOS %@ · iPresence", version] : @"on iOS · iPresence";
    NSMutableDictionary *activity = [@{
        @"application_id": @"1460106321427955903",
        @"name": [self trimString:artist toMaxLength:128],
        @"type": @2,
        @"details": [self trimString:title toMaxLength:128],
        @"state": [self trimString:[NSString stringWithFormat:@"%@ - %@", artist, album] toMaxLength:128],
        @"assets": @{@"large_text": [self trimString:text toMaxLength:128]}
    } mutableCopy];
    id start = metadata[@"start"], end = metadata[@"end"];
    if ([start isKindOfClass:NSNumber.class] && [end isKindOfClass:NSNumber.class] &&
        isfinite([start doubleValue]) && isfinite([end doubleValue]) && [start doubleValue] > 0 &&
        [end doubleValue] > [start doubleValue]) {
        activity[@"timestamps"] = @{@"start": start, @"end": end};
    }
    return activity;
}

- (NSString *)trimString:(NSString *)string toMaxLength:(NSUInteger)maximum {
    if (string.length <= maximum) return string;
    if (maximum < 3) return @"";
    // Do not cut a surrogate pair or composed emoji in the middle.
    __block NSUInteger length = 0;
    [string enumerateSubstringsInRange:NSMakeRange(0, string.length) options:NSStringEnumerationByComposedCharacterSequences
                           usingBlock:^(NSString *substring, NSRange range, NSRange enclosingRange, BOOL *stop) {
        if (NSMaxRange(range) > maximum - 3) *stop = YES;
        else length = NSMaxRange(range);
    }];
    return [[string substringToIndex:length] stringByAppendingString:@"..."];
}

- (void)awake:(NSNotification *)notification {
    if (![UserPreferences.sharedInstance valOfShowAsDiscordStatus]) return;
    self.state = PresenceUpdaterStateConnected;
    self.musicIsPlaying = [self.currentState[@"musicIsPlaying"] boolValue];
    self.sentPresence = NO;
    [self jsonSender]; // Also clear a resumed session when playback has stopped.
}

- (void)sleep:(NSNotification *)notification {
    self.state = PresenceUpdaterStateSleeping;
    [self.presenceCooldownTimer invalidate];
    self.presenceCooldownTimer = nil;
    self.pendingUpdate = NO;
}
@end
