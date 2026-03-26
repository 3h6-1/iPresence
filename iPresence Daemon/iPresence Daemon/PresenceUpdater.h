//
//  PresenceUpdater.m
//  iPresence-Daemon
//
//  Created by kainograze on 1/8/26.
//  Copyright (c) 2026 kainograze. All rights reserved.
//


#import <Foundation/Foundation.h>
#import "DCServerCommunicator.h"
#import "UserPreferences.h"

@interface PresenceUpdater : NSObject


typedef NS_ENUM(NSInteger, PresenceUpdaterState)
{
    PresenceUpdaterStateConnected,
    PresenceUpdaterStateSleeping
};
@property (atomic) PresenceUpdaterState state;

@property BOOL musicIsPlaying;
@property BOOL cooldownActive;
@property BOOL pendingUpdate;

@property (nonatomic, strong) NSTimer* presenceCooldownTimer;

@property (nonatomic, strong) NSDictionary* currentState;


+ (PresenceUpdater*) sharedInstance;

- (void) core: (NSNotification*) n;

- (void) jsonSender;

- (void) startSenderCooldown;
- (void) senderCooldownEnded;

- (NSDictionary*) generateValidActivityJson;
- (NSString *)trimString:(NSString *)string toMaxLength:(NSUInteger)maxLength;

- (void) awake: (NSNotification*) n;
- (void) sleep: (NSNotification*) n;

@end