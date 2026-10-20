// Original project by kainograze. Updated by 3h6_1.
//  Copyright (c) 2026 kainograze. All rights reserved.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

@interface Core : NSObject
@property (nonatomic) BOOL musicIsPlaying;
@property (nonatomic) BOOL isAwake;
@property (nonatomic, strong) NSTimer *asleepTimer;
@property (nonatomic, copy) NSDictionary *currentState;
@property (nonatomic, copy) NSString *pathToState;
+ (instancetype)sharedInstance;
- (void)start;
- (void)core;
- (void)setAwake;
- (void)setAsleep;
- (void)setAsleepTimer;
- (void)invalidateSetAsleepTimer;
- (void)editCurrentState;
- (void)settingsChanged:(NSNotification *)notification;
@end
