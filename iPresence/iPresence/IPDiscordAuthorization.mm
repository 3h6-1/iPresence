#import "IPDiscordAuthorization.h"
#import "../../shared/IPOAuthStore.h"
#define DISCORDPP_IMPLEMENTATION
#include "discordpp.h"
#include <memory>

static constexpr uint64_t IPApplicationID = 1561870047562043402ULL;
static const std::string IPRedirectURI = "discord-1561870047562043402:/authorize/callback";

static NSString *IPString(const std::string &value)
{
    return [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
}

@interface IPDiscordAuthorization () {
    std::unique_ptr<discordpp::Client> _client;
}
@property(nonatomic, readwrite) BOOL busy;
@property(nonatomic, strong) NSTimer *callbackTimer;
@end

@implementation IPDiscordAuthorization
+ (instancetype)sharedInstance
{
    static IPDiscordAuthorization *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}

- (void)startCallbacks
{
    NSAssert(NSThread.isMainThread, @"Discord callbacks must run on the main thread");
    if (!_client) {
        _client = std::make_unique<discordpp::Client>();
        _client->SetApplicationId(IPApplicationID);
        // Never attach a raw SDK log callback: auth diagnostics may contain secrets.
    }
    if (self.callbackTimer) return;
    self.callbackTimer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(__unused NSTimer *timer) {
        discordpp::RunCallbacks();
    }];
    self.callbackTimer.tolerance = 0.01;
    [NSRunLoop.mainRunLoop addTimer:self.callbackTimer forMode:NSRunLoopCommonModes];
}

- (void)finish:(BOOL)success message:(NSString *)message completion:(void (^)(BOOL, NSString *))completion
{
    self.busy = NO;
    [self.callbackTimer invalidate];
    self.callbackTimer = nil;
    completion(success, message);
}

- (void)revokeToken:(const std::string &)token completion:(void (^)(BOOL))completion
{
    if (token.empty()) { completion(YES); return; }
    // Revocation can invalidate all grants for this application/user, so no new
    // sign-in is started until it completes. Local logout already took effect.
    _client->RevokeToken(IPApplicationID, token, [completion](discordpp::ClientResult result) {
        completion(result.Successful());
    });
}

- (void)signInWithCompletion:(void (^)(BOOL, NSString *))completion
{
    if (self.busy) { completion(NO, @"An account request is already in progress."); return; }
    self.busy = YES;
    [self startCallbacks];
    auto verifier = _client->CreateAuthorizationCodeVerifier();
    discordpp::AuthorizationArgs args;
    args.SetClientId(IPApplicationID);
    args.SetScopes(discordpp::Client::GetDefaultPresenceScopes());
    args.SetCodeChallenge(verifier.Challenge());
    // The SDK supplies and validates OAuth state, and owns the native iOS
    // authorizer. The verifier lives only in this request's callback closure.
    _client->Authorize(args, [self, verifier, completion](discordpp::ClientResult result, std::string code, std::string redirectURI) {
        if (!result.Successful() || code.empty()) {
            NSString *message = result.Type() == discordpp::ErrorType::Aborted ? @"Sign-in cancelled." : @"Discord sign-in failed. Try again.";
            [self finish:NO message:message completion:completion];
            return;
        }
        if (redirectURI != IPRedirectURI) {
            [self finish:NO message:@"Discord returned an unexpected sign-in redirect." completion:completion];
            return;
        }
        self->_client->GetToken(IPApplicationID, code, verifier.Verifier(), redirectURI,
            [self, completion](discordpp::ClientResult tokenResult, std::string accessToken, std::string refreshToken,
                               discordpp::AuthorizationTokenType tokenType, int32_t expiresIn, std::string scopes) {
                if (!tokenResult.Successful()) {
                    [self finish:NO message:@"Discord could not finish sign-in. Try again." completion:completion];
                    return;
                }
                NSString *access = IPString(accessToken), *refresh = IPString(refreshToken), *scope = IPString(scopes);
                BOOL valid = tokenType == discordpp::AuthorizationTokenType::Bearer && access.length && refresh.length && scope.length && expiresIn > 0;
                NSDictionary *credentials = valid ? @{
                    @"accessToken": access,
                    @"refreshToken": refresh,
                    @"expiresAt": @(NSDate.date.timeIntervalSince1970 + expiresIn),
                    @"scope": scope,
                    @"sessionID": NSUUID.UUID.UUIDString
                } : nil;
                NSError *error = nil;
                if (!credentials || ![IPOAuthStore saveCredentials:credentials replacingSession:nil error:&error]) {
                    // A disk sync may fail after the atomic rename. Remove only
                    // this new session, never a different concurrent login.
                    if (credentials) [IPOAuthStore clearCredentialsIfSessionMatches:credentials[@"sessionID"]];
                    // Do not leave an issued grant behind when local storage fails.
                    // A refresh token can also be used to revoke if access is absent.
                    [self revokeToken:accessToken.empty() ? refreshToken : accessToken completion:^(__unused BOOL revoked) {
                        [self finish:NO message:@"Could not save sign-in privately. Install the rootless package and try again." completion:completion];
                    }];
                    return;
                }
                [IPOAuthStore notifyChanged];
                [self finish:YES message:@"Signed in with Discord." completion:completion];
            });
    });
}

- (void)signOutWithCompletion:(void (^)(BOOL, NSString *))completion
{
    if (self.busy) { completion(NO, @"An account request is already in progress."); return; }
    self.busy = YES;
    NSDictionary *credentials = [IPOAuthStore credentials];
    NSError *clearError = nil;
    BOOL cleared = [IPOAuthStore clearCredentialsWithError:&clearError];
    [IPOAuthStore notifyChanged];
    if (!cleared || [IPOAuthStore credentials]) {
        [self finish:NO message:@"Could not remove the saved sign-in. Try again." completion:completion];
        return;
    }
    NSString *token = credentials[@"refreshToken"] ?: credentials[@"accessToken"];
    if (!token.length) {
        [self finish:YES message:@"Signed out. Activity sharing is off." completion:completion];
        return;
    }
    [self startCallbacks];
    [self revokeToken:std::string(token.UTF8String) completion:^(BOOL revoked) {
        [self finish:YES message:revoked ? @"Signed out. Activity sharing is off." :
            @"Signed out on this device. Discord could not be reached to revoke access; you can remove iPresence in Discord’s Authorized Apps." completion:completion];
    }];
}
@end
