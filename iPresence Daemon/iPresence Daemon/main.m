#import <Foundation/Foundation.h>
#import "Bootstrap.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        [Bootstrap.sharedInstance start];
        [NSRunLoop.mainRunLoop run];
    }
    return 0;
}
