//
//  PresenceUpdater.m
//  iPresence-Daemon
//
//  Created by kainograze on 1/8/26.
//  Copyright (c) 2026 kainograze. All rights reserved.

/*
 
eu nao sei como fazer isso
 
 */
//

#import "PresenceUpdater.h"

@interface PresenceUpdater()

+ (PresenceUpdater*) sharedInstance;

@end

@implementation PresenceUpdater

#pragma mark - Singleton

+ (PresenceUpdater*) sharedInstance
{
    static PresenceUpdater* shared;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        shared = [PresenceUpdater new];
        
        [NSNotificationCenter.defaultCenter addObserver:shared selector:@selector(awake:) name:@"connected" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:shared selector:@selector(sleep:) name:@"sleep" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:shared selector:@selector(sleep:) name:@"idle" object:nil];
        
        [NSNotificationCenter.defaultCenter addObserver:shared selector:@selector(core:) name:@"playbackStateChanged" object:nil];
        
        shared.state = PresenceUpdaterStateSleeping;
        shared.musicIsPlaying = NO;
        shared.pendingUpdate = NO;
    });
    return shared;
}

#pragma mark - Core

- (void) core: (NSNotification*) n
{
    // listens to the media player notification, and, based on them and the current state, sets
    // flags and vars.
    
    self.currentState = n.userInfo;
    
    if (!self.currentState) return;
    if (self.state == PresenceUpdaterStateSleeping) return;
    
    [Logger Log: @"playback state changed!"];
    
    self.musicIsPlaying = [self.currentState [@"musicIsPlaying"] boolValue];
    
    [self jsonSender];
}

#pragma mark - JSON sender

- (void) jsonSender
{
    if (self.state == PresenceUpdaterStateSleeping) return;
    
    if (self.cooldownActive)
    {
        self.pendingUpdate = YES;
        return;
    }
    
    
    self.pendingUpdate = NO;
    [self startSenderCooldown];
    
    NSDictionary* jsonToSend = self.musicIsPlaying ? [self generateValidActivityJson] : nil;
//    NSDictionary* jsonToSend = [self generateValidActivityJson];
    
    [Logger Log: [jsonToSend description]];
    
    [Logger Log:@"sending activity json thru notification"];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"sendActivityJson" object:self userInfo:jsonToSend];
    });
}

#pragma mark - JSON creator

- (NSDictionary*) generateValidActivityJson
{
    
    NSString *artist = self.currentState[@"metadata"][@"artist"];
    NSString *song   = self.currentState[@"metadata"][@"title"];
    NSString *album = self.currentState[@"metadata"][@"album"];
    
    NSString *name    =  artist ? [self trimString: artist toMaxLength:128] : @"iPod";
    NSString *details = song ? [self trimString:song toMaxLength:128] : @"Unknown Song";
    NSString *state = album ? [self trimString:[NSString stringWithFormat:@"%@ - %@", name, album] toMaxLength:128] :
            [self trimString:[NSString stringWithFormat:@"%@ - Unknown Album", name] toMaxLength:128];
    NSString *textAsset = [UserPreferences.sharedInstance valOfDisplayIosVersion] ?
    [NSString stringWithFormat:@"on iOS %@ iPod App ♫", [UserPreferences.sharedInstance valOfIosVersion]] :
    @"on iPod App ♫";
    
    NSDictionary *json =
    @{
      @"application_id":@"1460106321427955903",
      @"name": name,
      @"type": @2,
      @"state": state,
      @"details": details,
      @"timestamps":
          @{
              @"start": self.currentState[@"metadata"][@"start"],
              @"end": self.currentState[@"metadata"][@"end"]
            },
      @"assets":
          @{
              @"large_text": textAsset
          }
      };
    
    return json;
}

#pragma mark - JSON sender cooldown

- (void) startSenderCooldown
{
    self.cooldownActive = YES;
    
    if (self.presenceCooldownTimer)
    {
        [self.presenceCooldownTimer invalidate];
        self.presenceCooldownTimer = nil;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.presenceCooldownTimer = [NSTimer scheduledTimerWithTimeInterval:5.5
                                                                      target:self
                                                                    selector:@selector(senderCooldownEnded)
                                                                    userInfo:nil
                                                                     repeats:NO];
    });
}

- (void) senderCooldownEnded
{
    self.cooldownActive = NO;
    
    if (self.presenceCooldownTimer)
    {
        [self.presenceCooldownTimer invalidate];
        self.presenceCooldownTimer = nil;
    }
    
    if(self.pendingUpdate)[self jsonSender];
}

- (NSString *)trimString:(NSString *)string toMaxLength:(NSUInteger)maxLength
{
    if (string.length <= maxLength)
    {
        return string;
    }
    
    NSUInteger limit = maxLength - 3;
    
    NSString *substring = [string substringToIndex:limit];
    
    NSRange range = [substring rangeOfCharacterFromSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]
                                               options:NSBackwardsSearch];
    
    if (range.location != NSNotFound)
    {
        substring = [substring substringToIndex:range.location];
    }
    
    return [substring stringByAppendingString:@"..."];
}

#pragma mark - Sleep, awake, and other state routines

- (void) awake: (NSNotification*) n
{
    if (![UserPreferences.sharedInstance valOfShowAsDiscordStatus]) return;
    
    [Logger Log:@"presence updater is awakening"];
    // is called only when the server communicator is connected to the webscoket (after READY)
    
    if (!self.currentState)
    {
        self.musicIsPlaying = NO;
        [Logger Log:@"presence updater is nil, won't awake"];
        return;
    }
    
    self.state = PresenceUpdaterStateConnected;
    
    self.musicIsPlaying = [self.currentState[@"musicIsPlaying"] boolValue];
    if (self.musicIsPlaying)
        [self jsonSender];
    
}

- (void) sleep: (NSNotification*) n
{
    // should stop the listening to the song and do nothing, just await for the next awake signal
    
    self.state = PresenceUpdaterStateSleeping;
}

@end