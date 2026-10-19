#import "DCServerCommunicator.h"
#import "IPOAuthStore.h"
#import "UserPreferences.h"
#import "Logger.h"
#import <math.h>

static BOOL NonemptyString(id value) { return [value isKindOfClass:NSString.class] && [value length] > 0; }
static BOOL ValidCredentials(NSDictionary *value) {
    return [value isKindOfClass:NSDictionary.class] && NonemptyString(value[@"accessToken"]) &&
        NonemptyString(value[@"refreshToken"]) && NonemptyString(value[@"sessionID"]) &&
        [value[@"expiresAt"] isKindOfClass:NSNumber.class] && isfinite([value[@"expiresAt"] doubleValue]);
}
static NSTimeInterval RetryDelay(NSError *error) {
    double delay = [error.userInfo[DCSDKRetryAfterKey] doubleValue];
    return isfinite(delay) ? MAX(30, MIN(delay, 3600)) : 30;
}

@interface DCServerCommunicator ()
@property (nonatomic, strong) id<DCDiscordTransport> transport;
@property (nonatomic, strong) NSTimer *callbackTimer;
@property (nonatomic, strong) NSTimer *maintenanceTimer;
@property (nonatomic, strong) NSTimer *presenceRetryTimer;
@property (nonatomic, copy) NSString *observedSession;
@property (nonatomic, copy) NSString *blockedSession;
@property (nonatomic, copy) NSString *refreshOperation;
@property (nonatomic, copy) NSString *appliedAccessToken;
@property (nonatomic, copy) NSDictionary *pendingActivity;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSUInteger authorizedGeneration;
@property (nonatomic) NSUInteger presenceRevision;
@property (nonatomic) BOOL updatingToken;
@property (nonatomic) BOOL forceRefresh;
@property (nonatomic) NSTimeInterval retryAt;
@end

@implementation DCServerCommunicator
+ (instancetype)sharedInstance {
    static DCServerCommunicator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [self new];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:shared selector:@selector(awake:) name:@"awake" object:nil];
        [center addObserver:shared selector:@selector(sleep:) name:@"sleep" object:nil];
        [center addObserver:shared selector:@selector(settingsChanged:) name:@"resetConnection" object:nil];
        [center addObserver:shared selector:@selector(sendActivityJson:) name:@"sendActivityJson" object:nil];
    });
    return shared;
}
- (instancetype)init { return [self initWithTransport:DCCreateDiscordTransport()]; }
- (instancetype)initWithTransport:(id<DCDiscordTransport>)transport {
    if ((self = [super init])) {
        _transport = transport;
        _state = DCConnectionStateDisconnected;
        _generation = 1;
        [self installCallbacks];
    }
    return self;
}
- (void)installCallbacks {
    NSUInteger generation = self.generation;
    __weak typeof(self) weakSelf = self;
    self.transport.statusChanged = ^(DCSocialSDKStatus status, BOOL authenticationFailure) {
        DCServerCommunicator *self = weakSelf;
        if (self && self.generation == generation) [self sdkStatusChanged:status authenticationFailure:authenticationFailure];
    };
    self.transport.tokenExpiring = ^{
        DCServerCommunicator *self = weakSelf;
        if (!self || self.generation != generation) return;
        self.forceRefresh = YES;
        [self serviceCredentials];
    };
}
- (void)startCommunicator {
    NSAssert(NSThread.isMainThread, @"The Discord SDK must run on the main queue");
    __weak typeof(self) weakSelf = self;
    if (!self.callbackTimer) {
        self.callbackTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
            [weakSelf.transport runCallbacks];
        }];
        self.callbackTimer.tolerance = 0.01;
    }
    if (!self.maintenanceTimer) {
        // The SDK's expiration callback does not run while disconnected. Keep an independent check.
        self.maintenanceTimer = [NSTimer scheduledTimerWithTimeInterval:15 repeats:YES block:^(NSTimer *timer) {
            [weakSelf serviceCredentials];
        }];
        self.maintenanceTimer.tolerance = 1;
    }
    [self serviceCredentials];
}
- (void)resetTransport {
    if (self.state != DCConnectionStateDisconnected) [Logger Log:@"Discord SDK disconnected."];
    self.generation++;
    [self installCallbacks];
    self.authorizedGeneration = 0;
    self.updatingToken = NO;
    self.appliedAccessToken = nil;
    self.pendingActivity = nil;
    self.presenceRevision++;
    [self.presenceRetryTimer invalidate];
    self.presenceRetryTimer = nil;
    [self.transport clearPresence];
    [self.transport disconnect];
    self.state = DCConnectionStateDisconnected;
    [NSNotificationCenter.defaultCenter postNotificationName:@"disconnected" object:self];
}
- (void)rejectSession:(NSString *)session {
    if (![self.observedSession isEqual:session]) return;
    self.blockedSession = session;
    [self resetTransport];
    if ([IPOAuthStore clearCredentialsIfSessionMatches:session]) [IPOAuthStore notifyChanged];
    [Logger Log:@"Discord authorization expired or was rejected. Link the account again in iPresence."];
}
- (BOOL)isCurrentSession:(NSString *)session {
    return session.length && [[IPOAuthStore credentials][@"sessionID"] isEqual:session];
}
- (void)serviceCredentials {
    NSAssert(NSThread.isMainThread, @"OAuth refresh must run on the main queue");
    NSDictionary *credentials = [IPOAuthStore credentials];
    if (!ValidCredentials(credentials)) credentials = nil;
    NSString *session = credentials[@"sessionID"];
    if (!((!session && !self.observedSession) || [session isEqual:self.observedSession])) {
        [self resetTransport];
        self.observedSession = session;
        self.blockedSession = nil;
        self.refreshOperation = nil;
        self.forceRefresh = NO;
        self.retryAt = 0;
    }
    if (!credentials || [self.blockedSession isEqual:session] || self.refreshOperation) return;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now < self.retryAt) return;
    if (self.forceRefresh || [credentials[@"expiresAt"] doubleValue] <= now + 90) {
        [self refreshCredentials:credentials];
        return;
    }
    if (!self.Active || ![UserPreferences.sharedInstance valOfShowAsDiscordStatus] || self.updatingToken) return;
    if (![self.appliedAccessToken isEqual:credentials[@"accessToken"]] || self.authorizedGeneration != self.generation) {
        [self applyCredentials:credentials];
    }
}
- (void)refreshCredentials:(NSDictionary *)credentials {
    NSString *session = credentials[@"sessionID"];
    NSString *operation = NSUUID.UUID.UUIDString;
    self.refreshOperation = operation;
    __weak typeof(self) weakSelf = self;
    [self.transport refreshToken:credentials[@"refreshToken"] completion:^(NSDictionary *tokens, NSError *error) {
        DCServerCommunicator *self = weakSelf;
        if (!self) return;
        BOOL currentOperation = [self.refreshOperation isEqual:operation];
        if (currentOperation) self.refreshOperation = nil;
        if (![self isCurrentSession:session]) {
            // Logout/new login won the race. Never restore it with a late refresh completion.
            // Only the app owns remote revocation: it invalidates every app/user grant and
            // an asynchronous daemon revocation could invalidate a subsequent login.
            return;
        }
        if (!currentOperation) return;
        if (error) {
            if ([error.userInfo[DCSDKAuthenticationFailureKey] boolValue]) [self rejectSession:session];
            else {
                self.retryAt = NSDate.date.timeIntervalSince1970 + RetryDelay(error);
                [Logger Log:@"Discord OAuth refresh failed; retry scheduled."];
            }
            return;
        }
        NSSet *scopes = [NSSet setWithArray:[tokens[@"scope"] isKindOfClass:NSString.class] ?
            [tokens[@"scope"] componentsSeparatedByString:@" "] : @[]];
        if (!NonemptyString(tokens[@"accessToken"]) || !NonemptyString(tokens[@"refreshToken"]) ||
            ![tokens[@"bearer"] boolValue] || ![tokens[@"expiresIn"] isKindOfClass:NSNumber.class] ||
            [tokens[@"expiresIn"] doubleValue] <= 0 || !isfinite([tokens[@"expiresIn"] doubleValue]) ||
            ![scopes containsObject:@"sdk.social_layer_presence"] || ![scopes containsObject:@"openid"]) {
            [self rejectSession:session];
            return;
        }
        NSDictionary *rotated = @{@"accessToken": tokens[@"accessToken"], @"refreshToken": tokens[@"refreshToken"],
            @"expiresAt": @(NSDate.date.timeIntervalSince1970 + [tokens[@"expiresIn"] doubleValue]),
            @"scope": tokens[@"scope"], @"sessionID": session};
        // Persist the rotated pair under a cross-process compare-and-swap BEFORE giving it to the SDK.
        if (![IPOAuthStore saveCredentials:rotated replacingSession:session error:NULL]) {
            if ([self isCurrentSession:session]) [self rejectSession:session];
            return;
        }
        self.forceRefresh = NO;
        self.retryAt = 0;
        // serviceCredentials rechecks both account and publishing state before UpdateToken/Connect.
        [self serviceCredentials];
    }];
}
- (void)applyCredentials:(NSDictionary *)credentials {
    NSUInteger generation = self.generation;
    NSString *session = credentials[@"sessionID"];
    NSString *access = credentials[@"accessToken"];
    self.updatingToken = YES;
    if (self.state != DCConnectionStateConnected) self.state = DCConnectionStateConnecting;
    __weak typeof(self) weakSelf = self;
    [self.transport updateAccessToken:access completion:^(NSError *error) {
        DCServerCommunicator *self = weakSelf;
        if (!self || generation != self.generation) return;
        self.updatingToken = NO;
        if (![self isCurrentSession:session] || !self.Active || ![UserPreferences.sharedInstance valOfShowAsDiscordStatus]) {
            [self resetTransport];
            return;
        }
        if (error) {
            if ([error.userInfo[DCSDKAuthenticationFailureKey] boolValue]) [self rejectSession:session];
            else {
                self.retryAt = NSDate.date.timeIntervalSince1970 + RetryDelay(error);
                [Logger Log:@"Discord SDK token update failed; retry scheduled."];
                [self resetTransport];
            }
            return;
        }
        self.appliedAccessToken = access;
        self.authorizedGeneration = generation;
        if (self.state == DCConnectionStateConnected) [self publishPendingActivity];
        else [self.transport connect];
    }];
}
- (void)sdkStatusChanged:(DCSocialSDKStatus)status authenticationFailure:(BOOL)authenticationFailure {
    if (!self.Active || ![UserPreferences.sharedInstance valOfShowAsDiscordStatus] ||
        ![self isCurrentSession:self.observedSession]) {
        if (status != DCSocialSDKStatusDisconnected) { [self.transport clearPresence]; [self.transport disconnect]; }
        self.state = DCConnectionStateDisconnected;
        return;
    }
    if (authenticationFailure) { [self rejectSession:self.observedSession]; return; }
    switch (status) {
        case DCSocialSDKStatusReady:
            if (self.authorizedGeneration != self.generation || self.updatingToken) return;
            if (self.state != DCConnectionStateConnected) [Logger Log:@"Discord SDK ready."];
            self.state = DCConnectionStateConnected;
            [NSNotificationCenter.defaultCenter postNotificationName:@"connected" object:self];
            break;
        case DCSocialSDKStatusReconnecting:
            if (self.state != DCConnectionStateReconnecting) [Logger Log:@"Discord SDK reconnecting."];
            self.state = DCConnectionStateReconnecting;
            [NSNotificationCenter.defaultCenter postNotificationName:@"disconnected" object:self];
            break;
        case DCSocialSDKStatusDisconnected:
            if (self.state != DCConnectionStateDisconnected) [Logger Log:@"Discord SDK disconnected; retry scheduled."];
            self.state = DCConnectionStateDisconnected;
            self.appliedAccessToken = nil;
            self.authorizedGeneration = 0;
            self.retryAt = MAX(self.retryAt, NSDate.date.timeIntervalSince1970 + 30);
            [NSNotificationCenter.defaultCenter postNotificationName:@"disconnected" object:self];
            break;
        case DCSocialSDKStatusConnecting: self.state = DCConnectionStateConnecting; break;
    }
}
- (void)publishPendingActivity {
    if (!self.Active || self.state != DCConnectionStateConnected || self.updatingToken || !self.pendingActivity ||
        ![self isCurrentSession:self.observedSession] || ![UserPreferences.sharedInstance valOfShowAsDiscordStatus]) return;
    NSUInteger generation = self.generation, revision = self.presenceRevision;
    __weak typeof(self) weakSelf = self;
    [self.transport updateActivity:self.pendingActivity completion:^(NSError *error) {
        DCServerCommunicator *self = weakSelf;
        if (!self || generation != self.generation || revision != self.presenceRevision || !error) return;
        if ([error.userInfo[DCSDKAuthenticationFailureKey] boolValue]) { [self rejectSession:self.observedSession]; return; }
        if ([error.userInfo[DCSDKRefreshRequiredKey] boolValue]) {
            self.forceRefresh = YES;
            [self serviceCredentials];
            return;
        }
        [self.presenceRetryTimer invalidate];
        [Logger Log:@"Discord activity update failed; retry scheduled."];
        self.presenceRetryTimer = [NSTimer scheduledTimerWithTimeInterval:RetryDelay(error) repeats:NO block:^(NSTimer *timer) {
            weakSelf.presenceRetryTimer = nil;
            [weakSelf publishPendingActivity];
        }];
    }];
}
- (void)sendActivityJson:(NSNotification *)notification {
    if (!self.Active || self.state != DCConnectionStateConnected) return;
    self.presenceRevision++;
    [self.presenceRetryTimer invalidate];
    self.presenceRetryTimer = nil;
    self.pendingActivity = notification.userInfo ? DCActivityForSocialSDK(notification.userInfo) : nil;
    if (!self.pendingActivity) [self.transport clearPresence];
    else [self publishPendingActivity];
}
- (void)awake:(NSNotification *)notification {
    if (![UserPreferences.sharedInstance valOfShowAsDiscordStatus] || ![UserPreferences.sharedInstance valOfLinkedAccount]) return;
    self.Active = YES;
    [self startCommunicator];
}
- (void)sleep:(NSNotification *)notification {
    self.Active = NO;
    [self resetTransport];
}
- (void)disconnect { [self sleep:nil]; }
- (void)settingsChanged:(NSNotification *)notification {
    [self resetTransport];
    if (![UserPreferences.sharedInstance valOfShowAsDiscordStatus]) self.Active = NO;
    [self serviceCredentials];
}
- (void)dealloc {
    [self.callbackTimer invalidate];
    [self.maintenanceTimer invalidate];
    [self.presenceRetryTimer invalidate];
    self.transport.statusChanged = nil;
    self.transport.tokenExpiring = nil;
}
@end
