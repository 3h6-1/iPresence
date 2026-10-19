// Offline integration fixture. This file is never linked into packaged builds.
// Both the web session and all HTTP transport are replaced; no Discord traffic.
#import <UIKit/UIKit.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <objc/runtime.h>
#import "IPDiscordAuthorization.h"
#import "AppDelegate.h"
#import "ViewController.h"
#import "IPOAuthStore.h"
#import "IPDiscordOAuthRequest.h"

@interface IPDiscordAuthorization (RoutingHarness)
- (ASWebAuthenticationSession *)newWebSessionWithURL:(NSURL *)url completion:(ASWebAuthenticationSessionCompletionHandler)completion;
- (NSURLSession *)newNetworkSession;
- (void)checkDeadline;
@end
static NSDictionary *AuthorizationFields;
static NSString *Scenario;
static NSUInteger TokenRequests, Completions, DelegateCalls, WebStarts;
static BOOL RequestValidated = YES, DelegateAccepted;
static ASWebAuthenticationSessionCompletionHandler StaleCompletion;
@interface ViewController (RoutingHarness)
- (void)signIn;
- (BOOL)persistPreferences;
@end
static void BeginSignIn(void);
static void (*OriginalSignIn)(id, SEL, void (^)(BOOL, NSString *));
static BOOL FixturePreferences(id self, SEL command) { return YES; }
static ViewController *Controller(void) {
    UINavigationController *navigation = (UINavigationController *)UIApplication.sharedApplication.delegate.window.rootViewController;
    return (ViewController *)navigation.topViewController;
}
static NSString *FixturePath(NSString *name) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:name];
}
static void WriteJSON(NSString *name, NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:NULL];
    [data writeToFile:FixturePath(name) atomically:YES];
}
static NSDictionary *Fields(NSString *form) {
    NSURLComponents *components = [NSURLComponents componentsWithString:[@"https://fixture.invalid/?" stringByAppendingString:form]];
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) if (item.name && item.value) fields[item.name] = item.value;
    return fields;
}
static BOOL DeliverURL(NSURL *url) {
    DelegateCalls++;
    AppDelegate *delegate = (AppDelegate *)UIApplication.sharedApplication.delegate;
    BOOL accepted = [delegate application:UIApplication.sharedApplication openURL:url options:@{}];
    DelegateAccepted |= accepted;
    return accepted;
}
static void ForceTimeout(void) {
    [IPDiscordAuthorization.sharedInstance setValue:@0 forKey:@"deadline"];
    [IPDiscordAuthorization.sharedInstance checkDeadline];
}
@interface IPFakeWebSession : ASWebAuthenticationSession
@property(nonatomic, copy) ASWebAuthenticationSessionCompletionHandler fakeCompletion;
@end
@implementation IPFakeWebSession
- (BOOL)start {
    WebStarts++;
    NSURLComponents *callback = [NSURLComponents componentsWithString:AuthorizationFields[@"redirect_uri"]];
    BOOL denied = [Scenario isEqualToString:@"denied"];
    callback.queryItems = @[[NSURLQueryItem queryItemWithName:denied ? @"error" : @"code" value:denied ? @"access_denied" : @"synthetic-code-not-real"],
                            [NSURLQueryItem queryItemWithName:@"state" value:AuthorizationFields[@"state"]]];
    NSURL *callbackURL = callback.URL;
    WriteJSON(@"AuthFixture.json", @{@"callbackURL": callbackURL.absoluteString, @"scenario": Scenario, @"ready": @YES});
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if ([Scenario isEqualToString:@"cancel"]) {
            [IPDiscordAuthorization.sharedInstance cancelSignIn];
            DeliverURL(callbackURL); // A late handoff must not save anything.
        } else if ([Scenario isEqualToString:@"timeout"]) {
            ForceTimeout();
            DeliverURL(callbackURL);
        } else if ([Scenario isEqualToString:@"browser-cancel"]) {
            self.fakeCompletion(nil, [NSError errorWithDomain:ASWebAuthenticationSessionErrorDomain code:ASWebAuthenticationSessionErrorCodeCanceledLogin userInfo:nil]);
        } else if ([Scenario isEqualToString:@"web-completion"]) {
            self.fakeCompletion(callbackURL, nil);
        } else if ([Scenario isEqualToString:@"external-url"]) {
            // Manual simctl openurl test; the simulator may show a system prompt.
        } else {
            if ([Scenario isEqualToString:@"forged-state"]) {
                NSURLComponents *forged = [NSURLComponents componentsWithURL:callbackURL resolvingAgainstBaseURL:NO];
                forged.queryItems = @[[NSURLQueryItem queryItemWithName:@"code" value:@"synthetic-code-not-real"], [NSURLQueryItem queryItemWithName:@"state" value:@"synthetic-wrong-state"]];
                if (DeliverURL(forged.URL) || !IPDiscordAuthorization.sharedInstance.busy) abort();
            }
            if ([Scenario isEqualToString:@"retry"] && WebStarts == 2 && StaleCompletion) {
                StaleCompletion(callbackURL, nil); // Prior generation cannot affect the retry.
            }
            DeliverURL(callbackURL);
            if ([Scenario isEqualToString:@"duplicate"]) DeliverURL(callbackURL);
        }
    });
    return YES;
}
- (void)cancel {
    // Cancellation can arrive after an explicit URL already began exchanging.
    if (self.fakeCompletion) self.fakeCompletion(nil, [NSError errorWithDomain:ASWebAuthenticationSessionErrorDomain code:ASWebAuthenticationSessionErrorCodeCanceledLogin userInfo:nil]);
}
@end

@interface IPAuthMockProtocol : NSURLProtocol
@property(atomic) BOOL stopped;
@end
@implementation IPAuthMockProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    TokenRequests++;
    NSData *body = self.request.HTTPBody;
    if (!body && self.request.HTTPBodyStream) {
        NSInputStream *stream = self.request.HTTPBodyStream;
        NSMutableData *read = [NSMutableData data];
        [stream open];
        uint8_t bytes[4096]; NSInteger count;
        while ((count = [stream read:bytes maxLength:sizeof(bytes)]) > 0) [read appendBytes:bytes length:(NSUInteger)count];
        [stream close]; body = read;
    }
    NSDictionary *fields = Fields([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"");
    NSString *challenge = [IPDiscordOAuthRequest challengeForVerifierForTesting:fields[@"code_verifier"] ?: @""];
    BOOL valid = [self.request.URL.absoluteString isEqualToString:@"https://discord.com/api/oauth2/token"] &&
        [self.request.HTTPMethod isEqualToString:@"POST"] &&
        [fields[@"client_id"] isEqualToString:@"1561870047562043402"] &&
        [fields[@"grant_type"] isEqualToString:@"authorization_code"] &&
        [fields[@"code"] isEqualToString:@"synthetic-code-not-real"] &&
        [fields[@"redirect_uri"] isEqualToString:AuthorizationFields[@"redirect_uri"]] &&
        [challenge isEqualToString:AuthorizationFields[@"code_challenge"]];
    RequestValidated &= valid;
    BOOL pending = [Scenario isEqualToString:@"exchange-cancel"] || [Scenario isEqualToString:@"exchange-timeout"] ||
        ([Scenario isEqualToString:@"retry"] && TokenRequests == 1);
    if (pending) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([Scenario isEqualToString:@"exchange-timeout"]) ForceTimeout();
            else [IPDiscordAuthorization.sharedInstance cancelSignIn];
        });
        return;
    }
    BOOL reject = [Scenario isEqualToString:@"server-error"] || !valid;
    NSDictionary *json = reject ? @{@"error": @"invalid_grant"} : @{
        @"access_token": @"synthetic-access-not-a-real-token", @"refresh_token": @"synthetic-refresh-not-a-real-token",
        @"token_type": @"Bearer", @"expires_in": @3600, @"scope": @"openid sdk.social_layer_presence"
    };
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:reject ? 400 : 200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[NSJSONSerialization dataWithJSONObject:json options:0 error:NULL]];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading { self.stopped = YES; }
@end
static ASWebAuthenticationSession *FakeWeb(id self, SEL command, NSURL *url, ASWebAuthenticationSessionCompletionHandler completion) NS_RETURNS_RETAINED;
static ASWebAuthenticationSession *FakeWeb(id self, SEL command, NSURL *url, ASWebAuthenticationSessionCompletionHandler completion) {
    AuthorizationFields = Fields(url.query ?: @"");
    IPFakeWebSession *session = [[IPFakeWebSession alloc] initWithURL:url callbackURLScheme:@"discord-1561870047562043402" completionHandler:completion];
    session.fakeCompletion = completion;
    if (!StaleCompletion) StaleCompletion = completion;
    return session;
}
static NSURLSession *FakeNetwork(id self, SEL command) NS_RETURNS_RETAINED;
static NSURLSession *FakeNetwork(id self, SEL command) {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses = @[IPAuthMockProtocol.class];
    return [NSURLSession sessionWithConfiguration:configuration];
}
static void ObserveSignIn(id self, SEL selector, void (^completion)(BOOL, NSString *)) {
    OriginalSignIn(self, selector, ^(BOOL success, NSString *message) {
        if (completion) completion(success, message);
        Completions++;
        if ([Scenario isEqualToString:@"retry"] && Completions == 1) {
            if (success || IPDiscordAuthorization.sharedInstance.busy || [IPOAuthStore credentials]) abort();
            dispatch_async(dispatch_get_main_queue(), ^{ BeginSignIn(); });
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            NSDictionary *credentials = [IPOAuthStore credentials];
            WriteJSON(@"AuthResult.json", @{
                @"scenario": Scenario, @"success": @(success), @"busy": @(IPDiscordAuthorization.sharedInstance.busy),
                @"tokenRequests": @(TokenRequests), @"requestValidated": @(RequestValidated), @"completions": @(Completions),
                @"delegateCalls": @(DelegateCalls), @"delegateAccepted": @(DelegateAccepted),
                @"storedSynthetic": @([credentials[@"accessToken"] isEqualToString:@"synthetic-access-not-a-real-token"]),
                @"message": message,
                @"signInEnabled": @([[Controller() valueForKey:@"signInButton"] isEnabled]),
                @"cancelHidden": @([[Controller() valueForKey:@"cancelSignInButton"] isHidden]),
                @"sharingEnabled": @([[Controller() valueForKey:@"enabledSwitch"] isOn]),
                @"statusText": [[Controller() valueForKey:@"statusLabel"] text] ?: @""
            });
            NSLog(@"AUTH_ROUTE_TEST completed scenario=%@ success=%d busy=%d", Scenario, success, IPDiscordAuthorization.sharedInstance.busy);
        });
    });
}
static void BeginSignIn(void) { [Controller() signIn]; }
__attribute__((constructor)) static void InstallRoutingHarness(void) {
    OriginalSignIn = (typeof(OriginalSignIn))method_setImplementation(class_getInstanceMethod(IPDiscordAuthorization.class, @selector(signInWithCompletion:)), (IMP)ObserveSignIn);
    method_setImplementation(class_getInstanceMethod(ViewController.class, @selector(persistPreferences)), (IMP)FixturePreferences);
    method_setImplementation(class_getInstanceMethod(IPDiscordAuthorization.class, @selector(newWebSessionWithURL:completion:)), (IMP)FakeWeb);
    method_setImplementation(class_getInstanceMethod(IPDiscordAuthorization.class, @selector(newNetworkSession)), (IMP)FakeNetwork);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        Scenario = NSProcessInfo.processInfo.environment[@"IP_AUTH_TEST_SCENARIO"] ?: @"success";
        NSString *directory = FixturePath(@"OAuthFixtureStore");
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:NULL];
        [IPOAuthStore setDirectoryForTesting:directory];
        [IPOAuthStore clearCredentials];
        [NSFileManager.defaultManager removeItemAtPath:FixturePath(@"AuthResult.json") error:NULL];
        BeginSignIn();
    });
}
