// Original project by kainograze. Updated by 3h6_1.
// Offline integration fixture. This file is never linked into packaged builds.
// Native handoff, web sessions, and all HTTP transport are replaced; no Discord traffic.
#import <UIKit/UIKit.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <objc/runtime.h>
#import "IPDiscordAuthorization.h"
#import "AppDelegate.h"
#import "ViewController.h"
#import "IPOAuthStore.h"
#import "IPDiagnostics.h"
#import "IPDiscordOAuthRequest.h"

@interface IPDiscordAuthorization (RoutingHarness)
- (ASWebAuthenticationSession *)newWebSessionWithURL:(NSURL *)url completion:(ASWebAuthenticationSessionCompletionHandler)completion;
- (NSURLSession *)newNetworkSession;
- (void)checkDeadline;
- (BOOL)canOpenDiscord;
- (void)openDiscordURL:(NSURL *)url completion:(void (^)(BOOL))completion;
- (void)signInUsingBrowserWithCompletion:(void (^)(BOOL, NSString *))completion;
@end
static NSDictionary *AuthorizationFields;
static NSString *Scenario;
static NSUInteger TokenRequests, Completions, DelegateCalls, WebStarts;
static NSUInteger NativeOpens, NativeAvailabilityChecks;
static BOOL RequestValidated = YES, DelegateAccepted, NativeRequestValidated = YES, BrowsersEphemeral = YES;
static ASWebAuthenticationSessionCompletionHandler StaleCompletion;
static void (^StaleNativeCompletion)(BOOL);
static NSURL *StaleNativeCallback;
@interface ViewController (RoutingHarness)
- (void)signIn;
- (void)signInUsingBrowser;
- (BOOL)persistPreferences;
@end
static void BeginSignIn(void);
static void (*OriginalSignIn)(id, SEL, void (^)(BOOL, NSString *));
static void (*OriginalBrowserSignIn)(id, SEL, void (^)(BOOL, NSString *));
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
static NSURL *CallbackForFields(NSDictionary *fields) {
    NSURLComponents *callback = [NSURLComponents componentsWithString:fields[@"redirect_uri"]];
    BOOL denied = [Scenario isEqualToString:@"denied"];
    callback.queryItems = @[[NSURLQueryItem queryItemWithName:denied ? @"error" : @"code" value:denied ? @"access_denied" : @"synthetic-code-not-real"],
                            [NSURLQueryItem queryItemWithName:@"state" value:fields[@"state"]]];
    return callback.URL;
}
@interface IPFakeWebSession : ASWebAuthenticationSession
@property(nonatomic, copy) ASWebAuthenticationSessionCompletionHandler fakeCompletion;
@end
@implementation IPFakeWebSession
- (BOOL)start {
    WebStarts++;
    BrowsersEphemeral &= self.prefersEphemeralWebBrowserSession;
    NSURL *callbackURL = CallbackForFields(AuthorizationFields);
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

static BOOL FakeCanOpenDiscord(id self, SEL command) {
    NativeAvailabilityChecks++;
    return [Scenario hasPrefix:@"native-"] || [Scenario isEqualToString:@"browser-explicit"];
}
static void FakeOpenDiscord(id self, SEL command, NSURL *url, void (^completion)(BOOL)) {
    NativeOpens++;
    AuthorizationFields = Fields(url.query ?: @"");
    NativeRequestValidated &= [url.scheme isEqualToString:@"discord"] && [url.host isEqualToString:@"view"] &&
        [url.path isEqualToString:@"/oauth2/authorize"] && AuthorizationFields.count == 7 &&
        [AuthorizationFields[@"client_id"] isEqualToString:@"1561870047562043402"] &&
        [AuthorizationFields[@"response_type"] isEqualToString:@"code"] &&
        [AuthorizationFields[@"scope"] isEqualToString:@"openid sdk.social_layer_presence"] &&
        [AuthorizationFields[@"code_method"] isEqualToString:@"S256"] &&
        [AuthorizationFields[@"redirect_uri"] isEqualToString:@"discord-1561870047562043402:/authorize/callback"] &&
        [AuthorizationFields[@"state"] length] == 43 && [AuthorizationFields[@"code_challenge"] length] == 43 &&
        AuthorizationFields[@"code_challenge_method"] == nil;
    NSURL *callbackURL = CallbackForFields(AuthorizationFields);
    WriteJSON(@"AuthFixture.json", @{@"callbackURL": callbackURL.absoluteString, @"scenario": Scenario, @"ready": @YES, @"native": @YES});
    NSUInteger invocation = NativeOpens;
    if ([Scenario isEqualToString:@"native-stale-open"] && invocation == 1) {
        StaleNativeCompletion = [completion copy];
        StaleNativeCallback = callbackURL;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [IPDiscordAuthorization.sharedInstance cancelSignIn];
        });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if ([Scenario isEqualToString:@"native-open-failure"]) {
            completion(NO); // Production must fall back to the mocked ephemeral browser.
            return;
        }
        if ([Scenario isEqualToString:@"native-stale-open"] && invocation == 2) {
            StaleNativeCompletion(NO); // Must not launch a browser for the cancelled generation.
            if (DeliverURL(StaleNativeCallback) || !IPDiscordAuthorization.sharedInstance.busy) abort();
        }
        completion(YES);
        // UIApplication's completion is asynchronous in production. Give its
        // main-queue handling time to settle before the simulated return URL.
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([Scenario isEqualToString:@"native-cancel"]) [IPDiscordAuthorization.sharedInstance cancelSignIn];
            else if ([Scenario isEqualToString:@"native-timeout"]) ForceTimeout();
            DeliverURL(callbackURL);
        });
    });
}

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
    void (*original)(id, SEL, void (^)(BOOL, NSString *)) = selector == @selector(signInUsingBrowserWithCompletion:) ? OriginalBrowserSignIn : OriginalSignIn;
    original(self, selector, ^(BOOL success, NSString *message) {
        if (completion) completion(success, message);
        Completions++;
        if (([Scenario isEqualToString:@"retry"] || [Scenario isEqualToString:@"native-stale-open"]) && Completions == 1) {
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
                @"webStarts": @(WebStarts), @"browsersEphemeral": @(BrowsersEphemeral),
                @"nativeOpens": @(NativeOpens), @"nativeAvailabilityChecks": @(NativeAvailabilityChecks),
                @"nativeRequestValidated": @(NativeRequestValidated),
                @"storedSynthetic": @([credentials[@"accessToken"] isEqualToString:@"synthetic-access-not-a-real-token"]),
                @"message": message,
                @"signInEnabled": @([[Controller() valueForKey:@"signInButton"] isEnabled]),
                @"browserSignInEnabled": @([[Controller() valueForKey:@"browserSignInButton"] isEnabled]),
                @"cancelHidden": @([[Controller() valueForKey:@"cancelSignInButton"] isHidden]),
                @"sharingEnabled": @([[Controller() valueForKey:@"enabledSwitch"] isOn]),
                @"statusText": [[Controller() valueForKey:@"statusLabel"] text] ?: @""
            });
            NSLog(@"AUTH_ROUTE_TEST completed scenario=%@ success=%d busy=%d", Scenario, success, IPDiscordAuthorization.sharedInstance.busy);
        });
    });
}
static void BeginSignIn(void) {
    if ([Scenario isEqualToString:@"browser-explicit"]) [Controller() signInUsingBrowser];
    else [Controller() signIn];
}
__attribute__((constructor)) static void InstallRoutingHarness(void) {
    NSString *diagnosticsDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/DiagnosticsFixture"];
    [NSFileManager.defaultManager createDirectoryAtPath:diagnosticsDirectory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:NULL];
    [IPDiagnostics setDirectoryForTesting:diagnosticsDirectory];
    OriginalSignIn = (typeof(OriginalSignIn))method_setImplementation(class_getInstanceMethod(IPDiscordAuthorization.class, @selector(signInWithCompletion:)), (IMP)ObserveSignIn);
    OriginalBrowserSignIn = (typeof(OriginalBrowserSignIn))method_setImplementation(class_getInstanceMethod(IPDiscordAuthorization.class, @selector(signInUsingBrowserWithCompletion:)), (IMP)ObserveSignIn);
    method_setImplementation(class_getInstanceMethod(ViewController.class, @selector(persistPreferences)), (IMP)FixturePreferences);
    method_setImplementation(class_getInstanceMethod(IPDiscordAuthorization.class, @selector(newWebSessionWithURL:completion:)), (IMP)FakeWeb);
    method_setImplementation(class_getInstanceMethod(IPDiscordAuthorization.class, @selector(newNetworkSession)), (IMP)FakeNetwork);
    method_setImplementation(class_getInstanceMethod(IPDiscordAuthorization.class, @selector(canOpenDiscord)), (IMP)FakeCanOpenDiscord);
    method_setImplementation(class_getInstanceMethod(IPDiscordAuthorization.class, @selector(openDiscordURL:completion:)), (IMP)FakeOpenDiscord);
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
