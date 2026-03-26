//
//  UserPreferences.h
//  iPresence-Daemon
//
//  Created by kainograze on 1/8/26.
//  Copyright (c) 2026 kainograze. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "Logger.h"
#import "DCServerCommunicator.h"

@interface UserPreferences : NSObject

@property (strong, nonatomic) NSDictionary* settings;
@property (strong, nonatomic) NSString* pathToSettings;
@property int settingsUpdatedAux;

+ (UserPreferences*) sharedInstance;

- (void) settingsUpdated;

- (NSString*) valOfToken;
- (BOOL) valOfShowAsDiscordStatus;
- (BOOL) valOfDisplayIosVersion;
- (NSString*) valOfIosVersion;
void settingsUpdated(CFNotificationCenterRef center, void* observer, CFStringRef name, const void *object, CFDictionaryRef userInfo);

@end
