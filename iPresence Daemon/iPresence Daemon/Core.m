//
//  Core.m
//  iPresence-Daemon
//
//  Created by kainograze on 1/9/26.
//  Copyright (c) 2026 kainograze. All rights reserved.
//


/*
 The core. it will decide when the application sleeps and awakes and whether the server communicator and presence updater
 should wake up. It receives the notifications from UserPreferences and will decide whether both classes should wake up
 or not. The awake and sleep signals are sent by notifications. The mentioned classes will the listening to these signals
 to decide if they should activate or not.
 
 */

#import "Core.h"

@interface Core()

+ (Core*) sharedInstance;

@end

@implementation Core

+ (Core*) sharedInstance
{
    static Core* shared = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        shared = [Core new];
        
        shared.isAwake = NO;
        shared.musicIsPlaying = NO;
        shared.settingsState = UPDATED;
        shared.editCurrentStateAux = 0;
        
        shared.pathToState = @"/var/mobile/Library/Preferences/com.kainograze.iPresence-Springboard-Helper.plist";
        
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void*)(shared), currentStateChanged, CFSTR("com.kainograze.iPresence-Springboard-Helper.State-Changed"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        
        [NSNotificationCenter.defaultCenter addObserver:shared selector:@selector(settingsChanged:) name:@"settingsChanged" object:nil];

    });
    
    return shared;
}

- (void) core
{
    if (!self.currentState) return;
    
    if (self.settingsState == RESTARTING) return;
    
    if (self.settingsState == MUST_RESTART)
    {
        self.settingsState = RESTARTING;
        
        [self setAsleep];
        
        // yes im making this long cuz i dont want spamming to break the daemon
        // we want all of those timers invalidated
        usleep(100 * 1000 * 50); //5 seconds
        
        [self setAwake];
        
        self.settingsState = UPDATED;
        
        if (![self.currentState[@"musicIsPlaying"] boolValue])
        {
            [self setAsleepTimer];
            return;
        }
    }
    
    [NSNotificationCenter.defaultCenter postNotificationName:@"playbackStateChanged" object:self userInfo:self.currentState];
    
    if ([self.currentState[@"musicIsPlaying"] boolValue]) [self setAwake];
    else [self setAsleepTimer];
}

void currentStateChanged (CFNotificationCenterRef center, void* observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
    [Logger Log:@"received darwin notification"];
    
    NSLog(@"received notification: current state has changed");
    
     Core* mySelf = (__bridge Core*)observer;
    
    [mySelf editCurrentState];
    [Logger Log: [mySelf.currentState description]];
    
    [mySelf core];
}

- (void) setAsleepTimer
{
    [self invalidateSetAsleepTimer];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.asleepTimer = [NSTimer scheduledTimerWithTimeInterval:300.0 //5 minutes
                                                            target:self
                                                          selector:@selector(setAsleep)
                                                          userInfo:nil
                                                           repeats:NO];
    });
}

- (void) invalidateSetAsleepTimer
{
    if (self.asleepTimer)
    {
        [self.asleepTimer invalidate];
        self.asleepTimer = nil;
    }
}

- (void) setAwake
{
    [self invalidateSetAsleepTimer];
    
    if (self.isAwake) return;
    
    self.isAwake = YES;
    
    NSLog(@"core is sending awake signal");
    dispatch_async(dispatch_get_main_queue(),^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"awake" object:self];
    });
    
}

- (void) setAsleep
{
    NSLog(@"core is sending asleep signal");
    [self invalidateSetAsleepTimer];
    
    self.isAwake = NO;
    
    dispatch_async(dispatch_get_main_queue(),^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"sleep" object:self];
    });
}

- (void) editCurrentState
{
    // sometimes the lock isnt patched correctly in some jailbreaks, this avoids getting null with cfpreferences
    
    self.currentState = [NSDictionary dictionaryWithContentsOfFile:self.pathToState][@"currentState"];
    
    if (!self.currentState && self.editCurrentStateAux <= 10)
    {
        //if we try to read the file while its being written, its gonna return null. retry with cooldown if that's the case
        self.editCurrentStateAux++;
        usleep(100 * 1000); // 100ms
        [self editCurrentState];
        return;
    }
    
    self.editCurrentStateAux = 0;
}

- (void) settingsChanged:(NSNotification *)n
{
    if (self.settingsState == RESTARTING || self.settingsState == MUST_RESTART) return;
    
    self.settingsState = MUST_RESTART;
    [self core];
}

@end
