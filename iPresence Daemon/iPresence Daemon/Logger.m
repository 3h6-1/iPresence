// Original project by kainograze. Updated by 3h6_1.
//  Copyright (c) 2026 kainograze. All rights reserved.
#import "Logger.h"

@implementation Logger
+ (void)Log:(NSString *)message {
    // Callers log lifecycle messages only. Never pass credentials or Gateway payloads here.
    if (message.length) NSLog(@"iPresence: %@", message);
}
+ (NSString *)GetLogs { return @"Logs are available in the system log."; }
+ (void)terminate {}
@end
