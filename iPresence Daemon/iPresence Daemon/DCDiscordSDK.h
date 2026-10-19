#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DCSocialSDKStatus) {
    DCSocialSDKStatusDisconnected,
    DCSocialSDKStatusConnecting,
    DCSocialSDKStatusReady,
    DCSocialSDKStatusReconnecting
};

// Adapter results intentionally omit SDK messages and response bodies, which can contain secrets.
FOUNDATION_EXPORT NSString *const DCSDKAuthenticationFailureKey;
FOUNDATION_EXPORT NSString *const DCSDKRetryAfterKey;
FOUNDATION_EXPORT NSString *const DCSDKRefreshRequiredKey;
typedef void (^DCSDKCompletion)(NSError * _Nullable error);
typedef void (^DCSDKRefreshCompletion)(NSDictionary * _Nullable tokens, NSError * _Nullable error);

@protocol DCDiscordTransport <NSObject>
@property (nonatomic, copy, nullable) void (^statusChanged)(DCSocialSDKStatus status, BOOL authenticationFailure);
@property (nonatomic, copy, nullable) void (^tokenExpiring)(void);
- (void)runCallbacks;
- (void)updateAccessToken:(NSString *)token completion:(DCSDKCompletion)completion;
- (void)refreshToken:(NSString *)token completion:(DCSDKRefreshCompletion)completion;
- (void)connect;
- (void)disconnect;
- (void)clearPresence;
// Timestamps are Unix seconds, as required by the Social SDK.
- (void)updateActivity:(NSDictionary *)activity completion:(DCSDKCompletion)completion;
@end

FOUNDATION_EXPORT id<DCDiscordTransport> DCCreateDiscordTransport(void);
FOUNDATION_EXPORT NSDictionary *DCActivityForSocialSDK(NSDictionary *activity);
FOUNDATION_EXPORT BOOL DCSDKErrorRequiresRelink(NSInteger status, BOOL tokenOperation,
                                              BOOL authorizationFailure, NSString * _Nullable oauthError);
NS_ASSUME_NONNULL_END
