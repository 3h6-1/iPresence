// Original project by kainograze. Updated by 3h6_1.
#import <Foundation/Foundation.h>
#import "IPAuthorizationAttempt.h"

static NSUInteger checks;
#define CHECK(condition, message) do { checks++; if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); exit(1); } } while (0)

int main(void) {
    @autoreleasepool {
        IPAuthorizationAttempt *attempt = [IPAuthorizationAttempt new];
        CHECK(!attempt.busy && attempt.phase == IPAuthorizationPhaseIdle, "Initial state is idle");
        CHECK(![attempt finish:0] && ![attempt canSave:0], "Zero is never a valid callback generation");
        NSUInteger first = [attempt beginSignIn];
        CHECK(first != 0 && attempt.busy && attempt.phase == IPAuthorizationPhaseAuthorizing, "Sign-in starts an identified operation");
        CHECK([attempt beginSignIn] == 0 && [attempt beginRevocation] == 0, "Concurrent account operations cannot start");
        CHECK(![attempt canSave:first], "Authorization alone cannot save credentials");
        CHECK(![attempt beginCleanupRevocation:first], "Cleanup cannot begin before token exchange");
        CHECK([attempt acceptAuthorization:first] && attempt.phase == IPAuthorizationPhaseExchanging, "Accepted authorization starts token exchange");
        CHECK(![attempt acceptAuthorization:first], "Duplicate authorization callback cannot exchange twice");
        CHECK([attempt canSave:first], "Current token exchange may persist its result");
        CHECK([attempt finish:first] && !attempt.busy, "Successful exchange releases the UI lock");
        CHECK(![attempt finish:first] && ![attempt canSave:first], "Duplicate exchange callback cannot finish or save again");

        NSUInteger cancelledAuthorization = [attempt beginSignIn];
        CHECK([attempt cancelSignIn:cancelledAuthorization] && !attempt.busy, "Authorization watchdog releases a stalled sign-in");
        NSUInteger afterCancel = [attempt beginSignIn];
        CHECK(afterCancel != cancelledAuthorization, "New sign-in has a distinct generation");
        CHECK(![attempt acceptAuthorization:cancelledAuthorization], "Late authorization cannot advance the new attempt");
        CHECK(![attempt finish:cancelledAuthorization] && attempt.busy, "Late authorization error cannot unlock a newer request");
        CHECK(![attempt cancelSignIn:cancelledAuthorization] && attempt.busy, "Old watchdog cannot cancel a newer request");
        CHECK([attempt acceptAuthorization:afterCancel], "New attempt remains usable after old callbacks");
        CHECK([attempt cancelSignIn:afterCancel] && ![attempt canSave:afterCancel], "Cancellation during exchange immediately prohibits credential persistence");
        NSUInteger afterExchangeCancel = [attempt beginSignIn];
        CHECK(![attempt canSave:afterCancel] && ![attempt beginCleanupRevocation:afterCancel], "Late-issued tokens cannot be saved or trigger cleanup against a newer login");
        CHECK([attempt acceptAuthorization:afterExchangeCancel] && [attempt canSave:afterExchangeCancel], "Current exchange can still complete");
        CHECK([attempt finish:afterExchangeCancel], "Current exchange completes exactly once");

        NSUInteger logout = [attempt beginRevocation];
        CHECK(logout != 0 && attempt.phase == IPAuthorizationPhaseRevoking, "Logout holds a revocation lock");
        CHECK([attempt beginSignIn] == 0, "New login cannot start while remote revocation is pending");
        CHECK(![attempt cancelSignIn:logout] && attempt.busy, "Sign-in watchdog cannot unlock an in-flight revocation");
        CHECK(![attempt acceptAuthorization:logout] && ![attempt canSave:logout], "Revocation cannot become an exchange or save credentials");
        CHECK(![attempt finish:first] && attempt.busy, "Stale sign-in completion cannot finish logout");
        CHECK([attempt finish:logout] && !attempt.busy, "Reported revocation completion, including network failure, releases its lock");
        NSUInteger afterLogout = [attempt beginSignIn];
        CHECK(afterLogout != logout && afterLogout != afterExchangeCancel, "Sign-in after logout owns a new generation");
        CHECK(![attempt finish:logout] && attempt.busy, "Duplicate logout completion cannot unlock new sign-in");
        CHECK([attempt acceptAuthorization:afterLogout], "Sign-in after logout reaches exchange");
        CHECK([attempt beginCleanupRevocation:afterLogout] && attempt.phase == IPAuthorizationPhaseRevoking, "Failed persistence can retain the lock during grant cleanup");
        CHECK(![attempt canSave:afterLogout] && [attempt beginSignIn] == 0, "Cleanup blocks further persistence and new sign-in");
        CHECK(![attempt cancelSignIn:afterLogout], "Sign-in timeout cannot end grant cleanup early");
        CHECK([attempt finish:afterLogout] && !attempt.busy, "Cleanup completion releases the operation");
        CHECK(![attempt finish:afterLogout], "Cleanup completion cannot be delivered twice");

        // Model UI completion and credential side effects exactly as the coordinator
        // must gate them, without timers, actual OAuth credentials, or network access.
        NSUInteger completions = 0, saves = 0;
        NSUInteger stale = [attempt beginSignIn];
        [attempt acceptAuthorization:stale];
        if ([attempt cancelSignIn:stale]) completions++;
        NSUInteger current = [attempt beginSignIn];
        [attempt acceptAuthorization:current];
        if ([attempt canSave:stale]) saves++;
        if ([attempt finish:stale]) completions++;
        CHECK(saves == 0 && completions == 1 && attempt.busy, "Cancelled request cannot save or deliver a second UI completion");
        if ([attempt canSave:current]) saves++;
        if ([attempt finish:current]) completions++;
        CHECK(saves == 1 && completions == 2 && !attempt.busy, "Only current attempt performs credential and UI effects");
        printf("Passed %lu authorization lifecycle checks (offline).\n", (unsigned long)checks);
    }
    return 0;
}
