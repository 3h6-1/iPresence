// Original project by kainograze. Updated by 3h6_1.
#import "DCDiscordSDK.h"
#define DISCORDPP_IMPLEMENTATION
#include "discordpp.h"

static constexpr uint64_t IPDiscordApplicationID = 1561870047562043402ULL;

static NSError *SDKError(const discordpp::ClientResult& result, bool tokenOperation = false) {
    if (result.Successful()) return nil;
    int status = static_cast<int>(result.Status());
    NSString *oauthError = nil;
    if (tokenOperation && status == 400) {
        std::string response = result.ResponseBody();
        NSData *data = [NSData dataWithBytes:response.data() length:response.size()];
        id body = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([body isKindOfClass:NSDictionary.class] && [body[@"error"] isKindOfClass:NSString.class]) oauthError = body[@"error"];
    }
    BOOL authenticationFailure = DCSDKErrorRequiresRelink(status, tokenOperation,
        result.Type() == discordpp::ErrorType::AuthorizationFailed, oauthError);
    return [NSError errorWithDomain:@"iPresence.DiscordSDK" code:static_cast<NSInteger>(result.Type())
                           userInfo:@{DCSDKAuthenticationFailureKey: @(authenticationFailure),
                                      DCSDKRetryAfterKey: @(result.RetryAfter()),
                                      DCSDKRefreshRequiredKey: @(!tokenOperation && status == 401)}];
}

@interface DCDiscordSDK : NSObject <DCDiscordTransport> {
    std::shared_ptr<discordpp::Client> _client;
}
@property (nonatomic, copy) void (^statusChanged)(DCSocialSDKStatus status, BOOL authenticationFailure);
@property (nonatomic, copy) void (^tokenExpiring)(void);
@end

@implementation DCDiscordSDK
- (instancetype)init {
    if ((self = [super init])) {
        _client = std::make_shared<discordpp::Client>();
        _client->SetApplicationId(IPDiscordApplicationID);
        // SDK logging remains disabled; only fixed, non-sensitive lifecycle messages are logged.
    }
    return self;
}
@synthesize statusChanged = _statusChanged;
@synthesize tokenExpiring = _tokenExpiring;
- (void)setStatusChanged:(void (^)(DCSocialSDKStatus, BOOL))callback {
    _statusChanged = [callback copy];
    // Capture this registration, so queued events cannot invoke a newer session's callback.
    _client->SetStatusChangedCallback([callback](discordpp::Client::Status status,
                                               discordpp::Client::Error, int32_t detail) {
        if (!callback) return;
        DCSocialSDKStatus mapped = DCSocialSDKStatusConnecting;
        switch (status) {
            case discordpp::Client::Status::Ready: mapped = DCSocialSDKStatusReady; break;
            case discordpp::Client::Status::Disconnected: mapped = DCSocialSDKStatusDisconnected; break;
            case discordpp::Client::Status::Reconnecting: mapped = DCSocialSDKStatusReconnecting; break;
            default: break;
        }
        callback(mapped, detail == 4004 || detail == 4012 || detail == 4013 || detail == 4014);
    });
}
- (void)setTokenExpiring:(void (^)(void))callback {
    _tokenExpiring = [callback copy];
    _client->SetTokenExpirationCallback([callback]() { if (callback) callback(); });
}
- (void)runCallbacks { discordpp::RunCallbacks(); }
- (void)updateAccessToken:(NSString *)token completion:(DCSDKCompletion)completion {
    _client->UpdateToken(discordpp::AuthorizationTokenType::Bearer, token.UTF8String,
                        [completion](discordpp::ClientResult result) { completion(SDKError(result, true)); });
}
- (void)refreshToken:(NSString *)token completion:(DCSDKRefreshCompletion)completion {
    _client->RefreshToken(IPDiscordApplicationID, token.UTF8String,
        [completion](discordpp::ClientResult result, std::string access, std::string refresh,
                     discordpp::AuthorizationTokenType type, int32_t expiresIn, std::string scope) {
            NSError *error = SDKError(result, true);
            if (error) { completion(nil, error); return; }
            NSDictionary *tokens = @{@"accessToken": @(access.c_str()), @"refreshToken": @(refresh.c_str()),
                                      @"expiresIn": @(expiresIn), @"scope": @(scope.c_str()),
                                      @"bearer": @(type == discordpp::AuthorizationTokenType::Bearer)};
            completion(tokens, nil);
        });
}
- (void)connect { _client->Connect(); }
- (void)disconnect { _client->Disconnect(); }
- (void)clearPresence { _client->ClearRichPresence(); }
- (void)updateActivity:(NSDictionary *)value completion:(DCSDKCompletion)completion {
    discordpp::Activity activity;
    activity.SetType(discordpp::ActivityTypes::Listening);
    activity.SetName([value[@"name"] UTF8String] ?: "iPresence");
    activity.SetDetails([value[@"details"] UTF8String] ?: "Unknown Song");
    activity.SetState([value[@"state"] UTF8String] ?: "Unknown Artist");
    NSDictionary *images = value[@"assets"];
    discordpp::ActivityAssets assets;
    if ([images[@"large_image"] isKindOfClass:NSString.class]) assets.SetLargeImage([images[@"large_image"] UTF8String]);
    if ([images[@"large_text"] isKindOfClass:NSString.class]) assets.SetLargeText([images[@"large_text"] UTF8String]);
    activity.SetAssets(assets);
    NSDictionary *times = value[@"timestamps"];
    if (times) {
        discordpp::ActivityTimestamps timestamps;
        timestamps.SetStart([times[@"start"] unsignedLongLongValue]);
        timestamps.SetEnd([times[@"end"] unsignedLongLongValue]);
        activity.SetTimestamps(timestamps);
    }
    _client->UpdateRichPresence(activity, [completion](discordpp::ClientResult result) { completion(SDKError(result)); });
}
@end

id<DCDiscordTransport> DCCreateDiscordTransport(void) { return [DCDiscordSDK new]; }
