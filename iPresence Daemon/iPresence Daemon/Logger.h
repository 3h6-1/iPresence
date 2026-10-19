//
//  Logger.h
//  iPresence-Daemon
//
//  Created by kainograze on 1/8/26.
//  Copyright (c) 2026 kainograze. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <stdio.h>

@interface Logger : NSObject

+ (void) Log: (NSString*) str;
+ (NSString*) GetLogs;
+ (void) terminate;

@end
