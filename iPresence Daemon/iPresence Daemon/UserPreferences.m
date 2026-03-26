//
//  UserPreferences.m
//  iPresence-Daemon
//
//  Created by kainograze on 1/8/26.
//  Copyright (c) 2026 kainograze. All rights reserved.
//

#import "UserPreferences.h"

@interface UserPreferences()

+ (UserPreferences*) sharedInstance;

@end

@implementation UserPreferences

+ (UserPreferences*) sharedInstance
{
    static UserPreferences* shared = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
        
        shared.pathToSettings = @"/var/mobile/Library/Preferences/com.kainograze.iPresence.plist";
        shared.settingsUpdatedAux = 0;
        
        //get values
        [shared settingsUpdated];
        
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void*)(shared), settingsUpdated, CFSTR("com.kainograze.iPresence.settingsChanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    });
    
    return shared;
}

void settingsUpdated(CFNotificationCenterRef center, void* observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
    UserPreferences* mySelf = (__bridge UserPreferences*)observer;
    
    [mySelf settingsUpdated];
    [NSNotificationCenter.defaultCenter postNotificationName:@"settingsChanged" object:mySelf userInfo:nil];
    NSLog(@"settings updated: %@", [mySelf.settings description]);
}

- (void) settingsUpdated
{
    self.settings = [NSDictionary dictionaryWithContentsOfFile:self.pathToSettings];
    
    if (!self.settings && self.settingsUpdatedAux <= 10)
    {
        // if it cant read the value after 10 tries just give up and accept the fate
        self.settingsUpdatedAux++;
        usleep(100 * 1000);
        [self settingsUpdated];
        return;
    }
    
    self.settingsUpdatedAux = 0;
    
}


- (NSString*) valOfToken
{
    return self.settings[@"token"];
}

- (BOOL) valOfShowAsDiscordStatus
{
    return [self.settings[@"showAsDiscordStatus"] boolValue];
}

- (BOOL) valOfDisplayIosVersion
{
    return [self.settings[@"displayIosVersion"] boolValue];
}

- (NSString*) valOfIosVersion
{
    return self.settings[@"iosVersion"];
}

@end
