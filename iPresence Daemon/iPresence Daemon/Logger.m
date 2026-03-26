//
//  Logger.m
//  iPresence-Daemon
//
//  Created by kainograze on 1/8/26.
//  Copyright (c) 2026 kainograze. All rights reserved.
//

#import "Logger.h"

static NSMutableArray* LogArray = nil;
static NSDateFormatter *dateFormatter;

@implementation Logger

+ (void)initialize
{
    if (self == [Logger class]) {
        LogArray = [[NSMutableArray alloc] init];
        [LogArray addObject:@"Logger - iTunes Rich Presence"];
        dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"dd/MM/yy HH:mm:ss"];
    }
}

+ (void) Log: (NSString*) str
{	    
    printf("%s\n", [str UTF8String]);
    NSLog(str);	
    
    if (!LogArray || !dateFormatter) return;
    
    NSDate* currentDate = [NSDate date];
    
    NSString* formattedDate = [dateFormatter stringFromDate:currentDate];
    
    NSString* logString = [NSString stringWithFormat:@"[%@] %@", formattedDate, str];
    
    #define MAX_LOG_LINES 500
    
    // limit how many lines there can be, so an overflow doesn't happen
    if (LogArray.count > MAX_LOG_LINES) {
        [LogArray removeObjectAtIndex:0];
    }
    
    //    NSLog(logString);
    [LogArray addObject:logString];
    
}

+(NSString*) GetLogs
{
    return [LogArray componentsJoinedByString:@"\n"];
}

+ (void) terminate
{
    LogArray = nil;
    dateFormatter = nil;
}

@end