// Original project by kainograze. Updated by 3h6_1.
//  Copyright (c) 2026 kainograze. All rights reserved.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

@interface UserPreferences : NSObject
@property (nonatomic, copy) NSDictionary *settings;
@property (nonatomic, copy) NSString *pathToSettings;
+ (instancetype)sharedInstance;
- (void)settingsUpdated;
- (BOOL)valOfLinkedAccount;
- (BOOL)valOfShowAsDiscordStatus;
- (BOOL)valOfDisplayIosVersion;
- (NSString *)valOfIosVersion;
@end
