#import "DCDiscordSDK.h"
#import <math.h>
#import <stdint.h>

NSString *const DCSDKAuthenticationFailureKey = @"authenticationFailure";
NSString *const DCSDKRetryAfterKey = @"retryAfter";
NSString *const DCSDKRefreshRequiredKey = @"refreshRequired";

BOOL DCSDKErrorRequiresRelink(NSInteger status, BOOL tokenOperation, BOOL authorizationFailure, NSString *oauthError) {
    // Presence validation/permission failures say nothing about the validity of the account link.
    return tokenOperation && (status == 401 || authorizationFailure ||
                             [oauthError isEqual:@"invalid_grant"] || [oauthError isEqual:@"invalid_token"]);
}

NSDictionary *DCActivityForSocialSDK(NSDictionary *activity) {
    NSMutableDictionary *result = [activity mutableCopy];
    [result removeObjectForKey:@"timestamps"];
    NSDictionary *timestamps = [activity[@"timestamps"] isKindOfClass:NSDictionary.class] ? activity[@"timestamps"] : nil;
    id start = timestamps[@"start"], end = timestamps[@"end"];
    if ([start isKindOfClass:NSNumber.class] && [end isKindOfClass:NSNumber.class]) {
        double startSeconds = floor([start doubleValue] / 1000.0);
        double endSeconds = floor([end doubleValue] / 1000.0);
        if (isfinite(startSeconds) && isfinite(endSeconds) && startSeconds > 0 &&
            endSeconds > startSeconds && endSeconds < (double)UINT64_MAX) {
            result[@"timestamps"] = @{@"start": @((uint64_t)startSeconds), @"end": @((uint64_t)endSeconds)};
        }
    }
    return result;
}
