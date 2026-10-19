#import <Foundation/Foundation.h>
#import "DCServerCommunicator.h"
#import "PresenceUpdater.h"
#import "UserPreferences.h"
#import "Core.h"
#import "Tools.h"

static NSUInteger checks;
#define CHECK(condition, message) do { checks++; if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); exit(1); } } while (0)

@interface DCServerCommunicator (Testing)
- (void)settingsChanged:(NSNotification *)notification;
@end

// No NSURLSession or external connection is created by these tests.
@interface TestSocket : NSObject
@property (nonatomic) NSInteger closeCode;
@property (nonatomic) NSUInteger cancelCount;
@end
@implementation TestSocket
- (void)cancelWithCloseCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason {
    self.closeCode = code;
    self.cancelCount++;
}
@end

@interface RecordingCommunicator : DCServerCommunicator
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *sent;
@property (nonatomic) NSUInteger starts;
@end
@implementation RecordingCommunicator
- (instancetype)init {
    if ((self = [super init])) _sent = [NSMutableArray new];
    return self;
}
- (void)sendJSON:(NSDictionary *)payload { [self.sent addObject:payload]; }
- (void)startCommunicator { self.starts++; }
@end

static RecordingCommunicator *Client(void) {
    RecordingCommunicator *client = [RecordingCommunicator new];
    client.Active = YES;
    client.state = DCConnectionStateConnecting;
    client.websocket = (NSURLSessionWebSocketTask *)(id)[TestSocket new];
    return client;
}

static void TestGateway(void) {
    RecordingCommunicator *client = Client();
    [client processTextCallback:@"not JSON"];
    [client processTextCallback:@"[]"];
    [client processTextCallback:@"{\"op\":null}"];
    CHECK(client.sent.count == 0, "Malformed gateway frames are ignored");
    [client processTextCallback:@"{\"op\":10,\"d\":{\"heartbeat_interval\":41250}}"];
    CHECK([client.sent.lastObject[@"op"] isEqual:@2], "Hello identifies a new session");
    CHECK([client.sent.lastObject[@"d"][@"large_threshold"] isKindOfClass:NSNumber.class], "Identify threshold is numeric");
    CHECK(fabs([[client valueForKey:@"heartbeatInterval"] doubleValue] - 41.25) < 0.001, "Fractional heartbeat milliseconds are retained");
    CHECK([client valueForKey:@"heartbeatTimer"] != nil, "Hello starts heartbeat timer");
    [client processTextCallback:@"{\"op\":1}"];
    CHECK(client.sent.lastObject[@"d"] == NSNull.null, "Heartbeat before any dispatch uses null sequence");
    [client processTextCallback:@"{\"op\":11}"];
    CHECK(![[client valueForKey:@"awaitingHeartbeatAck"] boolValue], "Heartbeat ACK clears pending state");
    [client processTextCallback:@"{\"op\":0,\"t\":\"READY\",\"s\":9007199254740993,\"d\":{\"session_id\":\"session\",\"resume_gateway_url\":\"wss://gateway-us-east1-b.discord.gg\"}}"];
    CHECK(client.state == DCConnectionStateConnected, "READY enters connected state");
    CHECK([[client valueForKey:@"sequenceNumber"] longLongValue] == 9007199254740993LL, "Sequence numbers do not truncate to 32 bits or double");
    CHECK([[client valueForKey:@"resumeGatewayURL"] containsString:@"v=10&encoding=json"], "Resume URL keeps gateway version and encoding");
    [client sendActivityJson:[NSNotification notificationWithName:@"sendActivityJson" object:nil]];
    CHECK([client.sent.lastObject[@"d"][@"activities"] isEqual:@[]], "Clearing activity sends an empty array");
    TestSocket *oldSocket = (id)client.websocket;
    [client processTextCallback:@"{\"op\":7}"];
    CHECK(client.state == DCConnectionStateReconnecting, "Opcode 7 initiates reconnect");
    CHECK(oldSocket.closeCode == 4000, "Reconnect does not invalidate resumable session with code 1000");
    CHECK([client valueForKey:@"sessionId"] != nil, "Reconnect retains session");
    NSTimer *retry = [client valueForKey:@"reconnectTimer"];
    [client reconnect];
    CHECK([client valueForKey:@"reconnectTimer"] == retry, "Concurrent transport failures schedule only one retry");
    [retry invalidate];
    [client setValue:nil forKey:@"reconnectTimer"];
    client.websocket = (NSURLSessionWebSocketTask *)(id)[TestSocket new];
    client.state = DCConnectionStateConnecting;
    [client processTextCallback:@"{\"op\":10,\"d\":{\"heartbeat_interval\":41250}}"];
    CHECK([client.sent.lastObject[@"op"] isEqual:@6], "Hello resumes a retained session");
    CHECK([client valueForKey:@"heartbeatTimer"] != nil, "Resumed connection has its own heartbeat timer");
    CHECK([client.sent.lastObject[@"d"][@"seq"] longLongValue] == 9007199254740993LL, "Resume carries exact sequence");
    [client processTextCallback:@"{\"op\":0,\"t\":\"RESUMED\",\"s\":9007199254740994,\"d\":{}}"];
    CHECK(client.state == DCConnectionStateConnected, "RESUMED enters connected state");
    [client setValue:@YES forKey:@"awaitingHeartbeatAck"];
    [client sendHeartbeat:nil];
    CHECK(client.state == DCConnectionStateReconnecting, "Missing heartbeat ACK reconnects");
    [client sleep:nil];
    CHECK(client.websocket == nil && [client valueForKey:@"reconnectTimer"] == nil && [client valueForKey:@"heartbeatTimer"] == nil, "Sleep cancels connection and timers");
    CHECK([client valueForKey:@"sessionId"] == nil, "Intentional normal close forgets invalidated session");

    client = Client();
    [client setValue:@"session" forKey:@"sessionId"];
    [client setValue:@5 forKey:@"sequenceNumber"];
    [client processTextCallback:@"{\"op\":9,\"d\":true}"];
    CHECK([client valueForKey:@"sessionId"] != nil, "Resumable invalid-session preserves session");
    [client sleep:nil];
    client = Client();
    [client setValue:@"session" forKey:@"sessionId"];
    [client processTextCallback:@"{\"op\":9,\"d\":false}"];
    CHECK([client valueForKey:@"sessionId"] == nil, "Non-resumable invalid-session clears session");
    [client sleep:nil];
    client = Client();
    [client processTextCallback:@"{\"op\":10,\"d\":null}"];
    CHECK(client.state == DCConnectionStateReconnecting, "Malformed Hello safely reconnects");
    [client sleep:nil];
    client = Client();
    [client processTextCallback:@"{\"op\":0,\"t\":\"READY\",\"s\":1,\"d\":{\"session_id\":\"session\",\"resume_gateway_url\":\"wss://attacker.example\"}}"];
    CHECK([client valueForKey:@"resumeGatewayURL"] == nil, "Resume rejects non-Discord destinations");
    [client processCloseCallback:4004 message:@"Do not log server payload"];
    CHECK(!client.Active && [[client valueForKey:@"authenticationBlocked"] boolValue], "Authentication failure stops retries");
    [client awake:nil];
    CHECK(client.starts == 0, "Playback cannot restart rejected authentication");
    [client settingsChanged:nil];
    [client awake:nil];
    CHECK(client.starts == 1, "Settings change permits corrected authentication");
    [client sleep:nil];
    client = Client();
    [client setValue:@"old" forKey:@"sessionId"];
    [client processCloseCallback:4007 message:nil];
    CHECK([client valueForKey:@"sessionId"] == nil, "Invalid sequence close clears session");
    [client sleep:nil];
}

static void TestPresence(void) {
    PresenceUpdater *updater = [PresenceUpdater new];
    updater.currentState = @{@"musicIsPlaying": @YES, @"metadata": @{@"title": @42, @"artist": NSNull.null, @"start": @1}};
    NSDictionary *activity = [updater generateValidActivityJson];
    CHECK([activity[@"details"] isEqual:@"Unknown Song"], "Invalid metadata types use safe defaults");
    CHECK(activity[@"timestamps"] == nil, "Missing end timestamp is omitted");
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
    [updater jsonSender];
    CHECK(sends == 2, "Unchanged 30-second helper heartbeat does not republish");
    [updater sleep:nil];
    CHECK(updater.presenceCooldownTimer == nil, "Sleep cancels pending presence timer");
    [NSNotificationCenter.defaultCenter removeObserver:observer];
}

static void TestStateAndPreferences(void) {
    NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:temporary withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *statePath = [temporary stringByAppendingPathComponent:@"state.plist"];
    Core *core = [Core new];
    core.pathToState = statePath;
    [core editCurrentState];
    CHECK(![core.currentState[@"musicIsPlaying"] boolValue], "Missing helper state is stopped");
    [@{@"currentState": @{@"musicIsPlaying": @YES, @"metadata": @{}, @"updatedAt": @(NSDate.date.timeIntervalSince1970 - 121)}} writeToFile:statePath atomically:YES];
    [core editCurrentState];
    CHECK(![core.currentState[@"musicIsPlaying"] boolValue], "Stale helper state is stopped");
    [@{@"currentState": @{@"musicIsPlaying": @YES, @"metadata": @{}, @"updatedAt": @(NSDate.date.timeIntervalSince1970)}} writeToFile:statePath atomically:YES];
    [core editCurrentState];
    CHECK([core.currentState[@"musicIsPlaying"] boolValue], "Fresh helper state accepted");
    [core core];
    CHECK(core.isAwake, "Playback wakes daemon");
    core.currentState = @{@"musicIsPlaying": @NO};
    [core core];
    NSTimer *idle = core.asleepTimer;
    [core core];
    CHECK(core.asleepTimer == idle, "Paused refreshes preserve fixed idle deadline");
    [core setAsleep];
    core.currentState = @{@"musicIsPlaying": @YES};
    [core core];
    CHECK(core.isAwake, "Playback restarts after idle sleep");
    [core setAsleep];
    RecordingCommunicator *client = Client();
    [client processCloseCallback:4004 message:nil];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:client selector:@selector(awake:) name:@"awake" object:nil];
    [center addObserver:client selector:@selector(sleep:) name:@"sleep" object:nil];
    [center addObserver:client selector:@selector(settingsChanged:) name:@"resetConnection" object:nil];
    core.isAwake = YES;
    [core settingsChanged:nil];
    CHECK(core.isAwake && client.Active && client.starts == 1, "Settings reset rejected authentication before waking active playback");
    UserPreferences.sharedInstance.settings = @{@"token": @"changed", @"showAsDiscordStatus": @NO};
    [core settingsChanged:nil];
    CHECK(!core.isAwake && !client.Active, "Disabling publishing disconnects without restarting playback");
    [center removeObserver:client];
    UserPreferences.sharedInstance.settings = @{@"token": @"test-only-credential", @"showAsDiscordStatus": @YES};
    [@{@"currentState": @{@"musicIsPlaying": @[@YES], @"metadata": @"bad", @"updatedAt": @(NSDate.date.timeIntervalSince1970)}} writeToFile:statePath atomically:YES];
    [core editCurrentState];
    CHECK(![core.currentState[@"musicIsPlaying"] boolValue] && [core.currentState[@"metadata"] isEqual:@{}], "Malformed helper values cannot crash daemon");
    UserPreferences *preferences = [UserPreferences new];
    preferences.pathToSettings = [temporary stringByAppendingPathComponent:@"prefs.plist"];
    [preferences settingsUpdated];
    CHECK(![preferences valOfShowAsDiscordStatus] && ![preferences valOfToken].length, "Missing settings disable activity");
    preferences.settings = @{@"token": @12, @"showAsDiscordStatus": @"yes", @"displayIosVersion": @[], @"iosVersion": @42};
    CHECK(![preferences valOfToken] && ![preferences valOfShowAsDiscordStatus] && ![preferences valOfDisplayIosVersion] && [[preferences valOfIosVersion] isEqual:@""], "Malformed preference values rejected");
    preferences.settings = @{@"token": @"  test-token\n"};
    CHECK([[preferences valOfToken] isEqual:@"test-token"], "Credential whitespace trimmed");
    CHECK([Tools parseJSON:@"[]"] == nil && [[Tools parseJSON:@"{\"value\":1}"][@"value"] isEqual:@1], "JSON parsing works on main thread without deadlock");
    [NSFileManager.defaultManager removeItemAtPath:temporary error:NULL];
}

int main(void) {
    @autoreleasepool {
        // A fake credential is only consumed by the recording subclass, never sent to the network.
        UserPreferences.sharedInstance.settings = @{@"token": @"test-only-credential", @"showAsDiscordStatus": @YES};
        TestGateway();
        TestPresence();
        TestStateAndPreferences();
        printf("Passed %lu daemon regression checks (offline).\n", (unsigned long)checks);
    }
    return 0;
}
