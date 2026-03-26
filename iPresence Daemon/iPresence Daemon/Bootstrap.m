//
//  Bootstrap.m
//  iPresence-Daemon
//
//  Created by kainograze on 1/9/26.
//  Copyright (c) 2026 kainograze. All rights reserved.
//

#import "Bootstrap.h"

@interface Bootstrap()

+ (Bootstrap*) sharedInstance;

@end

@implementation Bootstrap

+ (Bootstrap*) sharedInstance
{
    static Bootstrap* shared = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken,
    ^{
        shared = [Bootstrap new];
    });
    
    return shared;
}

- (void) start
{
    NSLog(@"bootstrap start");
    // logger won't be initialized in the release
    [Core sharedInstance];
    [UserPreferences sharedInstance];
    [DCServerCommunicator sharedInstance];
    [PresenceUpdater sharedInstance];
}

@end
