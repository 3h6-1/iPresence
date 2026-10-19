#import "IPDiscordAuthorization.h"
#import "../../shared/IPOAuthStore.h"
#import "../../shared/IPAuthorizationAttempt.h"
#import "../../shared/IPDiscordOAuthRequest.h"
#import <AuthenticationServices/AuthenticationServices.h>
#import <UIKit/UIKit.h>
#import <math.h>

NSNotificationName const IPDiscordAuthorizationStateDidChangeNotification = @"IPDiscordAuthorizationStateDidChange";

@interface IPDiscordAuthorization () <ASWebAuthenticationPresentationContextProviding, NSURLSessionTaskDelegate>
@property(nonatomic, strong) IPAuthorizationAttempt *attempt;
@property(nonatomic, strong) IPDiscordOAuthRequest *request;
@property(nonatomic, strong) ASWebAuthenticationSession *webSession;
@property(nonatomic, strong) NSURLSession *networkSession;
@property(nonatomic, strong) NSURLSessionDataTask *networkTask;
@property(nonatomic, strong) NSTimer *watchdog;
@property(nonatomic) NSTimeInterval deadline;
@property(nonatomic, copy) void (^completion)(BOOL, NSString *);
@end

@implementation IPDiscordAuthorization
+ (instancetype)sharedInstance {
    static IPDiscordAuthorization *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [self new]; });
    return shared;
}
- (instancetype)init {
    if ((self = [super init])) {
        _attempt = [IPAuthorizationAttempt new];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(checkDeadline)
            name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}
- (BOOL)busy { return self.attempt.isBusy; }
- (BOOL)canCancelSignIn {
    return self.attempt.phase == IPAuthorizationPhaseAuthorizing || self.attempt.phase == IPAuthorizationPhaseExchanging;
}
- (NSString *)progressMessage {
    switch (self.attempt.phase) {
        case IPAuthorizationPhaseAuthorizing: return @"Complete sign-in in the secure Discord window…";
        case IPAuthorizationPhaseExchanging: return @"Finishing Discord sign-in…";
        case IPAuthorizationPhaseRevoking: return @"Signing out…";
        default: return nil;
    }
}
- (void)notifyState {
    [NSNotificationCenter.defaultCenter postNotificationName:IPDiscordAuthorizationStateDidChangeNotification object:self];
}
- (UIWindow *)presentationWindow {
    return UIApplication.sharedApplication.delegate.window;
}
- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    return [self presentationWindow];
}
// Small factories allow simulator tests to replace the browser and HTTP transport.
- (ASWebAuthenticationSession *)newWebSessionWithURL:(NSURL *)url completion:(ASWebAuthenticationSessionCompletionHandler)completion {
    return [[ASWebAuthenticationSession alloc] initWithURL:url
        callbackURLScheme:[NSURL URLWithString:[IPDiscordOAuthRequest redirectURI]].scheme completionHandler:completion];
}
- (NSURLSession *)newNetworkSession {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache = nil;
    configuration.HTTPCookieStorage = nil;
    configuration.URLCredentialStorage = nil;
    configuration.timeoutIntervalForRequest = 30;
    configuration.timeoutIntervalForResource = 45;
    return [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    // OAuth codes and tokens must never follow a redirect to another destination.
    completionHandler(nil);
}
- (void)armDeadline:(NSTimeInterval)interval {
    self.deadline = NSProcessInfo.processInfo.systemUptime + interval;
    [self.watchdog invalidate];
    __weak typeof(self) weakSelf = self;
    self.watchdog = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf checkDeadline];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.watchdog forMode:NSRunLoopCommonModes];
}
- (void)checkDeadline {
    if (!self.busy || NSProcessInfo.processInfo.systemUptime < self.deadline) return;
    if (self.canCancelSignIn) {
        [self finish:self.attempt.generation success:NO message:@"Sign-in timed out. Please try again."];
    } else {
        // Wait for NSURLSession's cancellation completion before allowing a new
        // grant; revocation can affect every grant for this app/user.
        [self.networkTask cancel];
    }
}
- (void)finish:(NSUInteger)generation success:(BOOL)success message:(NSString *)message {
    if (![self.attempt finish:generation]) return;
    void (^completion)(BOOL, NSString *) = self.completion;
    self.completion = nil;
    self.request = nil;
    self.deadline = 0;
    [self.watchdog invalidate];
    self.watchdog = nil;
    ASWebAuthenticationSession *web = self.webSession;
    self.webSession = nil;
    [web cancel];
    [self.networkTask cancel];
    self.networkTask = nil;
    [self.networkSession invalidateAndCancel];
    self.networkSession = nil;
    [self notifyState];
    if (completion) completion(success, message);
}
- (void)cancelSignIn {
    if (!self.canCancelSignIn) return;
    // Invalidate the attempt before cancelling either callback source.
    [self finish:self.attempt.generation success:NO message:@"Sign-in cancelled."];
}
- (void)signInWithCompletion:(void (^)(BOOL, NSString *))completion {
    NSAssert(NSThread.isMainThread, @"Authorization runs on the main thread");
    NSUInteger generation = [self.attempt beginSignIn];
    if (!generation) { completion(NO, @"An account request is already in progress."); return; }
    self.completion = completion;
    self.request = [IPDiscordOAuthRequest new];
    if (!self.request || ![self presentationWindow]) {
        [self finish:generation success:NO message:@"Could not start secure sign-in. Please try again."];
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.webSession = [self newWebSessionWithURL:self.request.authorizationURL completion:^(NSURL *callbackURL, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            IPDiscordAuthorization *self = weakSelf;
            if (!self || self.attempt.generation != generation || self.attempt.phase != IPAuthorizationPhaseAuthorizing) return;
            if (error || !callbackURL) {
                BOOL cancelled = [error.domain isEqualToString:ASWebAuthenticationSessionErrorDomain] && error.code == ASWebAuthenticationSessionErrorCodeCanceledLogin;
                [self finish:generation success:NO message:cancelled ? @"Sign-in cancelled." : @"Discord sign-in could not finish. Please try again."];
            } else {
                [self acceptCallbackURL:callbackURL generation:generation fromWebSession:YES];
            }
        });
    }];
    self.webSession.presentationContextProvider = self;
    self.webSession.prefersEphemeralWebBrowserSession = NO;
    [self armDeadline:300];
    [self notifyState];
    if (![self.webSession start]) [self finish:generation success:NO message:@"Could not open Discord sign-in. Please try again."];
}
- (BOOL)handleOpenURL:(NSURL *)url {
    // Explicit UIKit delivery covers a browser/Discord app handoff; the normal
    // ASWebAuthenticationSession completion uses the exact same validated path.
    if (![IPDiscordOAuthRequest isCallbackURL:url] || self.attempt.phase != IPAuthorizationPhaseAuthorizing) return NO;
    return [self acceptCallbackURL:url generation:self.attempt.generation fromWebSession:NO];
}
- (BOOL)acceptCallbackURL:(NSURL *)url generation:(NSUInteger)generation fromWebSession:(BOOL)fromWebSession {
    if (self.attempt.generation != generation || self.attempt.phase != IPAuthorizationPhaseAuthorizing) return NO;
    NSError *error = nil;
    NSString *code = [self.request authorizationCodeFromURL:url error:&error];
    if (!code) {
        // Unsolicited or forged deep links cannot cancel an active sign-in.
        if (!fromWebSession && (error.code == IPDiscordOAuthRequestErrorStateMismatch ||
                                error.code == IPDiscordOAuthRequestErrorInvalidCallback)) return NO;
        [self finish:generation success:NO message:error.localizedDescription ?: @"Discord returned an invalid sign-in response. Please try again."];
        return YES;
    }
    if (![self.attempt acceptAuthorization:generation]) return NO;
    [self notifyState];
    NSURLRequest *request = [self.request tokenRequestForCode:code];
    if (!request) {
        [self finish:generation success:NO message:@"Discord returned an invalid sign-in code. Please try again."];
        return YES;
    }
    self.request = nil; // The request body now holds the verifier; it is never logged.
    ASWebAuthenticationSession *web = self.webSession;
    self.webSession = nil;
    [web cancel]; // Cancellation callback cannot act after the phase transition.
    [self armDeadline:45];
    self.networkSession = [self newNetworkSession];
    __weak typeof(self) weakSelf = self;
    self.networkTask = [self.networkSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *networkError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            IPDiscordAuthorization *self = weakSelf;
            if (!self || ![self.attempt canSave:generation]) return;
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            if (networkError || status != 200 || data.length > 65536) {
                [self finish:generation success:NO message:@"Discord could not complete sign-in. Check your connection and try again."];
                return;
            }
            id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            if (![json isKindOfClass:NSDictionary.class]) {
                [self finish:generation success:NO message:@"Discord returned an invalid sign-in response. Please try again."];
                return;
            }
            id access = json[@"access_token"], refresh = json[@"refresh_token"], scope = json[@"scope"], expires = json[@"expires_in"], type = json[@"token_type"];
            BOOL valid = [access isKindOfClass:NSString.class] && [access length] &&
                [refresh isKindOfClass:NSString.class] && [refresh length] && [scope isKindOfClass:NSString.class] &&
                [type isKindOfClass:NSString.class] && [type caseInsensitiveCompare:@"Bearer"] == NSOrderedSame &&
                [expires isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)expires) != CFBooleanGetTypeID() &&
                isfinite([expires doubleValue]) && [expires doubleValue] > 0;
            NSDictionary *credentials = valid ? @{@"accessToken": access, @"refreshToken": refresh, @"scope": scope,
                @"expiresAt": @(NSDate.date.timeIntervalSince1970 + [expires doubleValue]), @"sessionID": NSUUID.UUID.UUIDString} : nil;
            if (!credentials) {
                [self finish:generation success:NO message:@"Discord did not return the required presence authorization. Please try again."];
                return;
            }
            NSError *saveError = nil;
            if (![IPOAuthStore saveCredentials:credentials replacingSession:nil error:&saveError]) {
                [IPOAuthStore clearCredentialsIfSessionMatches:credentials[@"sessionID"]];
                [self finish:generation success:NO message:@"Could not save sign-in privately. Check that the rootless package is installed, then try again."];
                return;
            }
            [IPOAuthStore notifyChanged];
            [self finish:generation success:YES message:@"Signed in with Discord."];
        });
    }];
    [self.networkTask resume];
    return YES;
}
- (void)signOutWithCompletion:(void (^)(BOOL, NSString *))completion {
    NSAssert(NSThread.isMainThread, @"Authorization runs on the main thread");
    NSUInteger generation = [self.attempt beginRevocation];
    if (!generation) { completion(NO, @"An account request is already in progress."); return; }
    self.completion = completion;
    NSDictionary *credentials = [IPOAuthStore credentials];
    BOOL cleared = [IPOAuthStore clearCredentialsWithError:NULL];
    [IPOAuthStore notifyChanged];
    if (!cleared) {
        [self finish:generation success:NO message:@"Could not remove the saved sign-in. Please try again."];
        return;
    }
    NSString *token = credentials[@"refreshToken"];
    if (!token.length) {
        [self finish:generation success:YES message:@"Signed out. Activity sharing is off."];
        return;
    }
    [self armDeadline:45];
    [self notifyState];
    self.networkSession = [self newNetworkSession];
    __weak typeof(self) weakSelf = self;
    NSURLRequest *request = [IPDiscordOAuthRequest revocationRequestForToken:token];
    if (!request) {
        [self finish:generation success:YES message:@"Signed out on this device. Remove iPresence in Discord’s Authorized Apps to revoke access."];
        return;
    }
    self.networkTask = [self.networkSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            IPDiscordAuthorization *self = weakSelf;
            if (!self || self.attempt.generation != generation || self.attempt.phase != IPAuthorizationPhaseRevoking) return;
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            BOOL revoked = !error && status >= 200 && status < 300;
            [self finish:generation success:YES message:revoked ? @"Signed out. Activity sharing is off." :
                @"Signed out on this device. To revoke Discord access too, remove iPresence in Discord’s Authorized Apps."];
        });
    }];
    [self.networkTask resume];
}
@end
