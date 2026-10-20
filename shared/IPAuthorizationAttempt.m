// Original project by kainograze. Updated by 3h6_1.
#import "IPAuthorizationAttempt.h"

@implementation IPAuthorizationAttempt

- (BOOL)isBusy { return self.phase != IPAuthorizationPhaseIdle; }

- (void)advanceGeneration {
    // Zero is reserved for rejected begin requests.
    _generation = _generation == NSUIntegerMax ? 1 : _generation + 1;
}

- (NSUInteger)beginPhase:(IPAuthorizationPhase)phase {
    NSAssert(NSThread.isMainThread, @"Authorization state belongs to the main queue");
    if (self.busy) return 0;
    [self advanceGeneration];
    _phase = phase;
    return self.generation;
}

- (NSUInteger)beginSignIn { return [self beginPhase:IPAuthorizationPhaseAuthorizing]; }
- (NSUInteger)beginRevocation { return [self beginPhase:IPAuthorizationPhaseRevoking]; }

- (BOOL)matches:(NSUInteger)generation phase:(IPAuthorizationPhase)phase {
    return generation != 0 && generation == self.generation && self.phase == phase;
}

- (BOOL)acceptAuthorization:(NSUInteger)generation {
    NSAssert(NSThread.isMainThread, @"Authorization state belongs to the main queue");
    if (![self matches:generation phase:IPAuthorizationPhaseAuthorizing]) return NO;
    _phase = IPAuthorizationPhaseExchanging;
    return YES;
}

- (BOOL)canSave:(NSUInteger)generation {
    NSAssert(NSThread.isMainThread, @"Authorization state belongs to the main queue");
    return [self matches:generation phase:IPAuthorizationPhaseExchanging];
}

- (BOOL)beginCleanupRevocation:(NSUInteger)generation {
    NSAssert(NSThread.isMainThread, @"Authorization state belongs to the main queue");
    if (![self matches:generation phase:IPAuthorizationPhaseExchanging]) return NO;
    _phase = IPAuthorizationPhaseRevoking;
    return YES;
}

- (void)invalidate {
    _phase = IPAuthorizationPhaseIdle;
    [self advanceGeneration];
}

- (BOOL)finish:(NSUInteger)generation {
    NSAssert(NSThread.isMainThread, @"Authorization state belongs to the main queue");
    if (!self.busy || generation == 0 || generation != self.generation) return NO;
    [self invalidate];
    return YES;
}

- (BOOL)cancelSignIn:(NSUInteger)generation {
    NSAssert(NSThread.isMainThread, @"Authorization state belongs to the main queue");
    if (![self matches:generation phase:IPAuthorizationPhaseAuthorizing] &&
        ![self matches:generation phase:IPAuthorizationPhaseExchanging]) return NO;
    [self invalidate];
    return YES;
}

@end
