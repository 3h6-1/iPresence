//
//  Tools.m
//  iPresence-Daemon
//
//  Created by kainograze on 1/7/26.
//  Copyright (c) 2026 kainograze. All rights reserved.
//

// Special thanks to Discord Classic

#import "Tools.h"

@implementation Tools

+ (NSDictionary*)parseJSON:(NSString*)json
{
    __block id parsedResponse;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSError *error = nil;
        NSData *encodedResponseString = [json dataUsingEncoding:NSUTF8StringEncoding];
        parsedResponse = [NSJSONSerialization JSONObjectWithData:encodedResponseString options:0 error:&error];
        
    });
    if([parsedResponse isKindOfClass:NSDictionary.class]){
		return parsedResponse;
	}
	return nil;
}

@end
