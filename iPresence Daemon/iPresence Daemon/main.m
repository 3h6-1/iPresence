// Original project by kainograze. Updated by 3h6_1.
//  Copyright (c) 2026 kainograze. All rights reserved.
#import <Foundation/Foundation.h>
#import "Bootstrap.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        [Bootstrap.sharedInstance start];
        [NSRunLoop.mainRunLoop run];
    }
    return 0;
}
