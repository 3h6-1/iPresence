//
//  Core.h
//  iPresence-Daemon
//
//  Created by kainograze on 1/9/26.
//  Copyright (c) 2026 kainograze. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "Logger.h"

@interface Core : NSObject

@property BOOL musicIsPlaying;
@property BOOL isAwake;
@property int editCurrentStateAux;

@property (nonatomic, strong) NSTimer* asleepTimer;

@property (nonatomic, strong) NSDictionary* currentState;

@property (nonatomic, strong) NSString* pathToState;

typedef NS_ENUM(NSInteger, SettingsUpdateState)
{
    MUST_RESTART,
    RESTARTING,
    UPDATED
};

@property (atomic) SettingsUpdateState settingsState;

+ (Core*) sharedInstance;

void currentStateChanged (CFNotificationCenterRef center, void* observer, CFStringRef name, const void *object, CFDictionaryRef userInfo);

- (void) core;

- (void) setAwake;
- (void) setAsleep;

- (void) setAsleepTimer;
- (void) invalidateSetAsleepTimer;

- (void) editCurrentState;
- (void) settingsChanged: (NSNotification*) n;

@end