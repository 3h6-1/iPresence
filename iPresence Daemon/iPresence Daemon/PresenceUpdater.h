// Original project by kainograze. Updated by 3h6_1.
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, PresenceUpdaterState) {
    PresenceUpdaterStateConnected,
    PresenceUpdaterStateSleeping
};

@interface PresenceUpdater : NSObject
@property (nonatomic) PresenceUpdaterState state;
@property (nonatomic) BOOL musicIsPlaying;
@property (nonatomic) BOOL pendingUpdate;
@property (nonatomic, strong) NSTimer *presenceCooldownTimer;
@property (nonatomic, copy) NSDictionary *currentState;
+ (instancetype)sharedInstance;
- (void)core:(NSNotification *)notification;
- (void)jsonSender;
- (NSDictionary *)generateValidActivityJson;
- (NSString *)trimString:(NSString *)string toMaxLength:(NSUInteger)maximum;
- (void)awake:(NSNotification *)notification;
- (void)sleep:(NSNotification *)notification;
@end
