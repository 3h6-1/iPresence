#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, IPAuthorizationPhase) {
    IPAuthorizationPhaseIdle,
    IPAuthorizationPhaseAuthorizing,
    IPAuthorizationPhaseExchanging,
    IPAuthorizationPhaseRevoking
};

// Main-queue-only lifecycle guard. This class does not start timers, perform
// networking, save credentials, or revoke grants. Capture the returned generation
// in each callback and check it before any side effect or UI completion.
@interface IPAuthorizationAttempt : NSObject
@property (nonatomic, readonly) NSUInteger generation;
@property (nonatomic, readonly) IPAuthorizationPhase phase;
@property (nonatomic, readonly, getter=isBusy) BOOL busy;

// Returns zero if an operation is already pending.
- (NSUInteger)beginSignIn;
- (NSUInteger)beginRevocation;

// Accept an authorization result only once, before beginning its token exchange.
- (BOOL)acceptAuthorization:(NSUInteger)generation;
- (BOOL)canSave:(NSUInteger)generation;

// Keep a failed sign-in locked while its issued grant is being cleaned up.
- (BOOL)beginCleanupRevocation:(NSUInteger)generation;

// Only a current operation can finish and deliver its completion. Duplicate and
// stale callbacks return NO and must not update the UI or persisted credentials.
- (BOOL)finish:(NSUInteger)generation;

// Used by explicit cancellation and sign-in watchdogs. Invalidate the attempt
// before cancelling external work. Revocation is deliberately not cancellable
// here: its network completion must release the lock through finish:.
- (BOOL)cancelSignIn:(NSUInteger)generation;
@end

NS_ASSUME_NONNULL_END
