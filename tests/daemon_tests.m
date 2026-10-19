#import <Foundation/Foundation.h>
#import "DCServerCommunicator.h"
#import "PresenceUpdater.h"
#import "UserPreferences.h"
#import "Core.h"
#import "Tools.h"
#import "IPOAuthStore.h"

static NSUInteger checks;
#define CHECK(condition, message) do { checks++; if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); exit(1); } } while (0)

// The real credential store and iOS SDK are deliberately not linked into host tests.
// No test can read the user's credentials or connect to Discord.
static NSDictionary *storedCredentials;
static BOOL failStoreWrite;
static NSUInteger credentialWrites, credentialNotifications;
@implementation IPOAuthStore
+ (NSDictionary *)credentials { return storedCredentials; }
+ (BOOL)saveCredentials:(NSDictionary *)credentials replacingSession:(NSString *)session error:(NSError **)error {
    if (failStoreWrite || (session && ![storedCredentials[@"sessionID"] isEqual:session])) return NO;
    credentialWrites++;
    storedCredentials = [credentials copy];
    return YES;
}
+ (void)clearCredentials { storedCredentials = nil; }
+ (BOOL)clearCredentialsWithError:(NSError **)error { storedCredentials = nil; return YES; }
+ (BOOL)clearCredentialsIfSessionMatches:(NSString *)session {
    if (![storedCredentials[@"sessionID"] isEqual:session]) return NO;
    storedCredentials = nil;
    return YES;
}
+ (void)notifyChanged { credentialNotifications++; }
@end

@interface FakeSDK : NSObject <DCDiscordTransport>
@property (nonatomic, copy) void (^statusChanged)(DCSocialSDKStatus, BOOL);
@property (nonatomic, copy) void (^tokenExpiring)(void);
@property (nonatomic, strong) NSMutableArray *tokenCompletions;
@property (nonatomic, strong) NSMutableArray *refreshCompletions;
@property (nonatomic, strong) NSMutableArray *activityCompletions;
@property (nonatomic, strong) NSMutableArray *updatedTokens;
@property (nonatomic, strong) NSMutableArray *refreshTokens;
@property (nonatomic, strong) NSMutableArray *activities;
@property (nonatomic) NSUInteger connects;
@property (nonatomic) NSUInteger disconnects;
@property (nonatomic) NSUInteger clears;
@property (nonatomic) NSUInteger callbacks;
@property (nonatomic) BOOL appliedOnlyPersistedTokens;
- (void)completeToken:(NSUInteger)index error:(NSError *)error;
- (void)completeRefresh:(NSUInteger)index tokens:(NSDictionary *)tokens error:(NSError *)error;
- (void)completeActivity:(NSUInteger)index error:(NSError *)error;
@end
@implementation FakeSDK
- (instancetype)init {
    if ((self = [super init])) {
        _tokenCompletions = [NSMutableArray new]; _refreshCompletions = [NSMutableArray new];
        _activityCompletions = [NSMutableArray new]; _updatedTokens = [NSMutableArray new];
        _refreshTokens = [NSMutableArray new];
        _activities = [NSMutableArray new]; _appliedOnlyPersistedTokens = YES;
    }
    return self;
}
- (void)runCallbacks { self.callbacks++; }
- (void)updateAccessToken:(NSString *)token completion:(DCSDKCompletion)completion {
    self.appliedOnlyPersistedTokens &= [storedCredentials[@"accessToken"] isEqual:token];
    [self.updatedTokens addObject:token]; [self.tokenCompletions addObject:[completion copy]];
}
- (void)refreshToken:(NSString *)token completion:(DCSDKRefreshCompletion)completion {
    [self.refreshTokens addObject:token]; [self.refreshCompletions addObject:[completion copy]];
}
- (void)connect { self.connects++; }
- (void)disconnect { self.disconnects++; }
- (void)clearPresence { self.clears++; }
- (void)updateActivity:(NSDictionary *)activity completion:(DCSDKCompletion)completion {
    [self.activities addObject:activity]; [self.activityCompletions addObject:[completion copy]];
}
- (void)completeToken:(NSUInteger)index error:(NSError *)error {
    DCSDKCompletion callback = self.tokenCompletions[index]; callback(error);
}
- (void)completeRefresh:(NSUInteger)index tokens:(NSDictionary *)tokens error:(NSError *)error {
    DCSDKRefreshCompletion callback = self.refreshCompletions[index]; callback(tokens, error);
}
- (void)completeActivity:(NSUInteger)index error:(NSError *)error {
    DCSDKCompletion callback = self.activityCompletions[index]; callback(error);
}
@end
id<DCDiscordTransport> DCCreateDiscordTransport(void) { return [FakeSDK new]; }

static NSDictionary *Credentials(NSString *session, BOOL expired) {
    return @{@"accessToken": @"fake-access", @"refreshToken": @"fake-refresh",
             @"expiresAt": @(NSDate.date.timeIntervalSince1970 + (expired ? -10 : 3600)),
             @"scope": @"openid sdk.social_layer_presence", @"sessionID": session};
}
static NSDictionary *RotatedTokens(void) {
    return @{@"accessToken": @"fake-rotated-access", @"refreshToken": @"fake-rotated-refresh",
             @"expiresIn": @3600, @"scope": @"openid sdk.social_layer_presence", @"bearer": @YES};
}
static NSError *Failure(BOOL authentication) {
    return [NSError errorWithDomain:@"FakeSDK" code:1 userInfo:@{DCSDKAuthenticationFailureKey: @(authentication)}];
}
static void ResetCredentials(BOOL expired) {
    storedCredentials = Credentials(@"session-A", expired);
    failStoreWrite = NO; credentialWrites = 0; credentialNotifications = 0;
    UserPreferences.sharedInstance.settings = @{@"showAsDiscordStatus": @YES};
}
static void TestSocialSDK(void) {
    CHECK(!DCSDKErrorRequiresRelink(400, NO, NO, nil), "Invalid activity payload does not erase OAuth credentials");
    CHECK(!DCSDKErrorRequiresRelink(403, NO, NO, nil), "Activity permission failure does not erase OAuth credentials");
    CHECK(!DCSDKErrorRequiresRelink(401, NO, NO, nil), "Presence token expiry permits a refresh before relinking");
    CHECK(DCSDKErrorRequiresRelink(400, YES, NO, @"invalid_grant"), "OAuth invalid_grant requires a fresh account link");
    CHECK(!DCSDKErrorRequiresRelink(400, YES, NO, @"invalid_client"), "Application configuration failure preserves the user's link");
    ResetCredentials(NO);
    FakeSDK *sdk = [FakeSDK new];
    DCServerCommunicator *client = [[DCServerCommunicator alloc] initWithTransport:sdk];
    [client awake:nil];
    CHECK(sdk.updatedTokens.count == 1 && sdk.connects == 0, "Connect waits for UpdateToken completion");
    sdk.statusChanged(DCSocialSDKStatusReady, NO);
    CHECK(client.state != DCConnectionStateConnected, "Early Ready cannot bypass token initialization");
    [sdk completeToken:0 error:nil];
    CHECK(sdk.connects == 1, "Successful bearer token initialization starts SDK connection");
    sdk.statusChanged(DCSocialSDKStatusReady, NO);
    CHECK(client.state == DCConnectionStateConnected, "SDK Ready enables presence publication");
    [[client valueForKey:@"callbackTimer"] fire];
    CHECK(sdk.callbacks == 1, "Main-runloop timer pumps SDK callbacks");
    NSDictionary *activity = @{@"name": @"Artist", @"timestamps": @{@"start": @1700000000123LL, @"end": @1700000300999LL}};
    [client sendActivityJson:[NSNotification notificationWithName:@"sendActivityJson" object:nil userInfo:activity]];
    CHECK([sdk.activities.lastObject[@"timestamps"][@"start"] isEqual:@1700000000], "SDK presence receives seconds instead of helper milliseconds");
    [sdk completeActivity:0 error:Failure(NO)];
    CHECK([client valueForKey:@"presenceRetryTimer"] != nil, "Transient presence error schedules retry");
    [client sendActivityJson:[NSNotification notificationWithName:@"sendActivityJson" object:nil]];
    CHECK(sdk.clears > 0 && [client valueForKey:@"presenceRetryTimer"] == nil, "Paused playback clears presence and cancels stale retries");
    [client sendActivityJson:[NSNotification notificationWithName:@"sendActivityJson" object:nil userInfo:activity]];
    [sdk completeActivity:1 error:[NSError errorWithDomain:@"FakeSDK" code:401 userInfo:@{DCSDKRefreshRequiredKey: @YES}]];
    CHECK(sdk.refreshTokens.count == 1 && storedCredentials, "Presence 401 refreshes the linked OAuth account");
    [sdk completeRefresh:0 tokens:RotatedTokens() error:nil];
    [sdk completeToken:1 error:nil];
    CHECK(sdk.activities.count == 3 && sdk.connects == 1, "Refresh republishes pending presence when the SDK remains connected");
    void (^oldStatus)(DCSocialSDKStatus, BOOL) = sdk.statusChanged;
    NSUInteger disconnects = sdk.disconnects;
    [client sleep:nil];
    CHECK(!client.Active && sdk.disconnects > disconnects, "Idle disconnects the SDK");
    oldStatus(DCSocialSDKStatusReady, NO);
    CHECK(client.state == DCConnectionStateDisconnected, "Queued old-session status callback cannot wake an idle connection");
    [sdk completeActivity:0 error:Failure(NO)];
    CHECK([client valueForKey:@"presenceRetryTimer"] == nil, "Late presence failure after sleep cannot schedule work");

    ResetCredentials(NO);
    sdk = [FakeSDK new]; client = [[DCServerCommunicator alloc] initWithTransport:sdk];
    [client awake:nil]; [client sleep:nil]; [sdk completeToken:0 error:nil];
    CHECK(sdk.connects == 0, "UpdateToken completing after disable cannot connect");

    ResetCredentials(YES);
    sdk = [FakeSDK new]; client = [[DCServerCommunicator alloc] initWithTransport:sdk];
    [client startCommunicator]; [client serviceCredentials];
    CHECK(sdk.refreshTokens.count == 1 && sdk.updatedTokens.count == 0, "Expired credentials refresh at startup while disconnected, with one refresh in flight");
    [sdk completeRefresh:0 tokens:RotatedTokens() error:nil];
    CHECK(credentialWrites == 1 && [storedCredentials[@"refreshToken"] isEqual:@"fake-rotated-refresh"], "Rotated access and refresh credentials persist together");
    CHECK(sdk.updatedTokens.count == 0 && sdk.connects == 0, "Background refresh does not publish while inactive");
    [client awake:nil];
    CHECK(sdk.appliedOnlyPersistedTokens && [sdk.updatedTokens.lastObject isEqual:@"fake-rotated-access"], "Only durably stored rotated credentials reach UpdateToken");
    [sdk completeToken:0 error:nil]; sdk.statusChanged(DCSocialSDKStatusReady, NO);
    sdk.tokenExpiring();
    CHECK(sdk.refreshTokens.count == 2, "SDK token-expiration callback requests a refresh before stored expiration");
    [client sleep:nil];
    [sdk completeRefresh:1 tokens:RotatedTokens() error:nil];
    CHECK(credentialWrites == 2 && sdk.updatedTokens.count == 1, "Refresh finishing after disable persists tokens without reconnecting");

    ResetCredentials(YES);
    sdk = [FakeSDK new]; client = [[DCServerCommunicator alloc] initWithTransport:sdk];
    [client awake:nil]; [IPOAuthStore clearCredentials]; [client serviceCredentials];
    [sdk completeRefresh:0 tokens:RotatedTokens() error:nil];
    CHECK(!storedCredentials && sdk.updatedTokens.count == 0, "Logout wins over an in-flight token refresh");
    CHECK(credentialWrites == 0, "Late refresh credentials are discarded while logged out");

    ResetCredentials(YES);
    sdk = [FakeSDK new]; client = [[DCServerCommunicator alloc] initWithTransport:sdk];
    [client awake:nil]; oldStatus = sdk.statusChanged;
    storedCredentials = Credentials(@"session-B", NO); [client serviceCredentials];
    [sdk completeRefresh:0 tokens:RotatedTokens() error:nil];
    CHECK([storedCredentials[@"sessionID"] isEqual:@"session-B"] && credentialWrites == 0, "Late refresh cannot overwrite a newer login");
    CHECK(sdk.updatedTokens.count == 1 && [sdk.updatedTokens.lastObject isEqual:@"fake-access"], "Only the newer login's token is applied after a stale refresh");
    oldStatus(DCSocialSDKStatusDisconnected, YES);
    CHECK([storedCredentials[@"sessionID"] isEqual:@"session-B"], "Old SDK authorization failure cannot delete a newer login");

    ResetCredentials(YES);
    sdk = [FakeSDK new]; client = [[DCServerCommunicator alloc] initWithTransport:sdk];
    [client awake:nil]; failStoreWrite = YES;
    [sdk completeRefresh:0 tokens:RotatedTokens() error:nil];
    CHECK(!storedCredentials && sdk.updatedTokens.count == 0 && credentialNotifications == 1, "Failed rotated-token persistence discards unusable credentials and requires sign-in");

    ResetCredentials(YES);
    sdk = [FakeSDK new]; client = [[DCServerCommunicator alloc] initWithTransport:sdk];
    [client awake:nil]; [sdk completeRefresh:0 tokens:nil error:Failure(YES)];
    [client serviceCredentials];
    CHECK(!storedCredentials && credentialNotifications == 1 && sdk.refreshTokens.count == 1, "Rejected refresh clears only its session and stops retries");

    ResetCredentials(YES);
    sdk = [FakeSDK new]; client = [[DCServerCommunicator alloc] initWithTransport:sdk];
    [client awake:nil]; [sdk completeRefresh:0 tokens:nil error:Failure(NO)]; [client serviceCredentials];
    CHECK(storedCredentials && sdk.refreshTokens.count == 1, "Transient refresh errors preserve account and respect backoff");
    [client setValue:@0 forKey:@"retryAt"]; [client serviceCredentials];
    CHECK(sdk.refreshTokens.count == 2, "Disconnected maintenance retries refresh after backoff");

    ResetCredentials(YES);
    sdk = [FakeSDK new]; client = [[DCServerCommunicator alloc] initWithTransport:sdk];
    [client awake:nil]; NSMutableDictionary *invalid = [RotatedTokens() mutableCopy]; invalid[@"bearer"] = @NO;
    [sdk completeRefresh:0 tokens:invalid error:nil];
    CHECK(!storedCredentials && sdk.updatedTokens.count == 0, "Personal session tokens cannot enter the Social SDK transport");

    storedCredentials = nil;
    UserPreferences.sharedInstance.settings = @{@"showAsDiscordStatus": @YES, @"token": @"unused-legacy-value"};
    sdk = [FakeSDK new]; client = [[DCServerCommunicator alloc] initWithTransport:sdk];
    [client awake:nil];
    CHECK(!client.Active && sdk.updatedTokens.count == 0 && sdk.refreshTokens.count == 0, "Legacy plaintext token preferences never enable a connection");
    CHECK([DCActivityForSocialSDK(activity)[@"timestamps"][@"end"] isEqual:@1700000300], "Timestamp conversion floors milliseconds to SDK seconds");
    CHECK([activity[@"timestamps"][@"start"] isEqual:@1700000000123LL], "SDK conversion does not mutate helper metadata");
    CHECK(DCActivityForSocialSDK(@{@"timestamps": @{@"start": @2000, @"end": @1000}})[@"timestamps"] == nil, "SDK conversion drops reversed timestamps");
    CHECK(DCActivityForSocialSDK(@{@"timestamps": @{@"start": @(NAN), @"end": @(INFINITY)}})[@"timestamps"] == nil, "SDK conversion rejects nonfinite timestamps");
    ResetCredentials(NO);
}

static void TestPresence(void) {
    PresenceUpdater *updater = [PresenceUpdater new];
    updater.currentState = @{@"musicIsPlaying": @YES, @"metadata": @{@"title": @42, @"artist": NSNull.null, @"start": @1}};
    NSDictionary *activity = [updater generateValidActivityJson];
    CHECK([activity[@"application_id"] isEqual:@"1561870047562043402"], "Activity uses the user's iPresence application with the updated fallback icon");
    CHECK([activity[@"details"] isEqual:@"Unknown Song"], "Invalid metadata types use safe defaults");
    CHECK(activity[@"timestamps"] == nil, "Missing end timestamp is omitted");
    NSString *artworkURL = activity[@"assets"][@"large_image"];
    CHECK([artworkURL isEqual:@"https://raw.githubusercontent.com/3h6-1/iPresence/main/assets/apple-music-ios26.webp"], "Activity explicitly selects the supplied red/pink Apple Music artwork");
    NSURL *artwork = [NSURL URLWithString:artworkURL];
    CHECK([artwork.scheme isEqual:@"https"] && artwork.host.length && !artwork.user && !artwork.password, "Artwork is a public HTTPS URL without embedded credentials");
    CHECK([activity[@"assets"][@"large_text"] isEqual:@"on iOS · iPresence"], "Explicit artwork preserves the iPresence tooltip");
    updater.currentState = @{@"metadata": @{@"start": @2000, @"end": @1000}};
    CHECK([updater generateValidActivityJson][@"timestamps"] == nil, "Reversed timestamps are omitted");
    updater.currentState = @{@"metadata": @{@"start": @1000, @"end": @2000}};
    CHECK([[updater generateValidActivityJson][@"timestamps"][@"end"] isEqual:@2000], "Valid timestamps retained");
    NSString *emoji = [@"👨‍👩‍👧‍👦" stringByPaddingToLength:220 withString:@"👨‍👩‍👧‍👦" startingAtIndex:0];
    NSString *trimmed = [updater trimString:emoji toMaxLength:128];
    CHECK(trimmed.length <= 128 && [trimmed dataUsingEncoding:NSUTF8StringEncoding] != nil, "Truncation preserves Unicode");
    __block NSUInteger sends = 0;
    __block NSDictionary *lastActivity;
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:@"sendActivityJson" object:updater queue:nil usingBlock:^(NSNotification *notification) {
        sends++;
        lastActivity = notification.userInfo;
    }];
    updater.currentState = @{@"musicIsPlaying": @NO};
    [updater awake:nil];
    CHECK(sends == 1 && lastActivity == nil, "Connected while paused clears any prior presence");
    [updater core:[NSNotification notificationWithName:@"playbackStateChanged" object:nil userInfo:@{@"musicIsPlaying": @YES, @"metadata": @{@"title": @"New Track"}}]];
    CHECK(sends == 1 && updater.presenceCooldownTimer != nil, "Rapid update is coalesced during rate limit");
    [updater setValue:@0 forKey:@"lastSendTime"];
    [updater.presenceCooldownTimer fire];
    CHECK(sends == 2 && [lastActivity[@"details"] isEqual:@"New Track"], "Cooldown publishes most recent playback");
    CHECK([lastActivity[@"assets"][@"large_image"] isEqual:artworkURL], "Coalesced playback update retains the Apple Music artwork");
    [updater jsonSender];
    CHECK(sends == 2, "Unchanged 30-second helper heartbeat does not republish");
    [updater sleep:nil];
    CHECK(updater.presenceCooldownTimer == nil, "Sleep cancels pending presence timer");
    [NSNotificationCenter.defaultCenter removeObserver:observer];
}

static void TestStateAndPreferences(void) {
    ResetCredentials(NO);
    NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:temporary withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *statePath = [temporary stringByAppendingPathComponent:@"state.plist"];
    Core *core = [Core new]; core.pathToState = statePath;
    [core editCurrentState];
    CHECK(![core.currentState[@"musicIsPlaying"] boolValue], "Missing helper state is stopped");
    [@{@"currentState": @{@"musicIsPlaying": @YES, @"metadata": @{}, @"updatedAt": @(NSDate.date.timeIntervalSince1970 - 121)}} writeToFile:statePath atomically:YES];
    [core editCurrentState];
    CHECK(![core.currentState[@"musicIsPlaying"] boolValue], "Stale helper state is stopped");
    [@{@"currentState": @{@"musicIsPlaying": @YES, @"metadata": @{}, @"updatedAt": @(NSDate.date.timeIntervalSince1970)}} writeToFile:statePath atomically:YES];
    [core editCurrentState]; [core core];
    CHECK([core.currentState[@"musicIsPlaying"] boolValue] && core.isAwake, "Fresh playback and OAuth credentials wake daemon");
    core.currentState = @{@"musicIsPlaying": @NO}; [core core];
    NSTimer *idle = core.asleepTimer; [core core];
    CHECK(core.asleepTimer == idle, "Paused refreshes preserve fixed idle deadline");
    [core setAsleep]; core.currentState = @{@"musicIsPlaying": @YES}; [core core];
    CHECK(core.isAwake, "Playback restarts after idle sleep");
    [IPOAuthStore clearCredentials]; [core core];
    CHECK(!core.isAwake, "Account unlink stops publication even during playback");
    ResetCredentials(NO);
    UserPreferences.sharedInstance.settings = @{@"showAsDiscordStatus": @NO};
    [core settingsChanged:nil];
    CHECK(!core.isAwake, "Disabling publication prevents a settings reset from waking playback");
    [@{@"currentState": @{@"musicIsPlaying": @[@YES], @"metadata": @"bad", @"updatedAt": @(NSDate.date.timeIntervalSince1970)}} writeToFile:statePath atomically:YES];
    [core editCurrentState];
    CHECK(![core.currentState[@"musicIsPlaying"] boolValue] && [core.currentState[@"metadata"] isEqual:@{}], "Malformed helper values cannot crash daemon");
    UserPreferences *preferences = [UserPreferences new];
    preferences.pathToSettings = [temporary stringByAppendingPathComponent:@"prefs.plist"]; [preferences settingsUpdated];
    CHECK(![preferences valOfShowAsDiscordStatus], "Missing settings disable activity");
    preferences.settings = @{@"showAsDiscordStatus": @"yes", @"displayIosVersion": @[], @"iosVersion": @42};
    CHECK(![preferences valOfShowAsDiscordStatus] && ![preferences valOfDisplayIosVersion] && [[preferences valOfIosVersion] isEqual:@""], "Malformed preference values rejected");
    CHECK([preferences valOfLinkedAccount], "OAuth linkage comes from credential store");
    [IPOAuthStore clearCredentials]; preferences.settings = @{@"token": @"legacy"};
    CHECK(![preferences valOfLinkedAccount], "Legacy preferences cannot impersonate OAuth account linkage");
    CHECK([Tools parseJSON:@"[]"] == nil && [[Tools parseJSON:@"{\"value\":1}"][@"value"] isEqual:@1], "JSON parsing works on main thread without deadlock");
    [NSFileManager.defaultManager removeItemAtPath:temporary error:NULL];
}

int main(void) {
    @autoreleasepool {
        TestSocialSDK();
        TestPresence();
        TestStateAndPreferences();
        printf("Passed %lu daemon regression checks (offline; fake SDK and credential store).\n", (unsigned long)checks);
    }
    return 0;
}
