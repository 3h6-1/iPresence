//
//  main.m
//  iPresence-Daemon
//
//  Created by kainograze on 1/9/26.
//  Copyright (c) 2026 kainograze. All rights reserved.
//

/*
 
 SDK=$(xcrun --sdk iphoneos --show-sdk-path)
 SRC=$(find . -name "*.m")
 
 xcrun --sdk iphoneos clang \
 -o iPresence-Daemon\
 -arch armv7 \
 -arch armv7s \
 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
 -miphoneos-version-min=5.0 	\
 -fobjc-arc \
 -framework Foundation \
 -framework CoreFoundation \
 -framework Security \
 -framework CFNetwork \
 -Os \
 -Wl,-dead_strip\
 *.m
 
 */

#import <Foundation/Foundation.h>
#import "Bootstrap.h"

int main(int argc, char *argv[])
{
    @autoreleasepool
    {
        NSLog(@"daemon started");
        dispatch_async(dispatch_get_main_queue(), ^{
            [Bootstrap.sharedInstance start];
        });
        [NSRunLoop.mainRunLoop run];
    }
    return 0;
}
