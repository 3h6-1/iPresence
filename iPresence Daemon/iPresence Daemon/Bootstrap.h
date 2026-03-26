//
//  Bootstrap.h
//  iPresence-Daemon
//
//  Created by kainograze on 1/9/26.
//  Copyright (c) 2026 kainograze. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "DCServerCommunicator.h"
#import "PresenceUpdater.h"
#import "UserPreferences.h"
#import "Core.h"

@interface Bootstrap : NSObject

+ (Bootstrap*) sharedInstance;
- (void) start;

@end
