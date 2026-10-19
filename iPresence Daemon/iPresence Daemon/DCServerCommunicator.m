#import "DCServerCommunicator.h"
#import "UserPreferences.h"
#import "Logger.h"
#import <math.h>

static NSString *const DCDefaultGateway = @"wss://gateway.discord.gg/?v=10&encoding=json";

@interface DCServerCommunicator ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, copy) NSString *sessionId;
@property (nonatomic, copy) NSString *resumeGatewayURL;
@property (nonatomic, strong) NSNumber *sequenceNumber;
@property (nonatomic, strong) NSTimer *heartbeatTimer;
@property (nonatomic, strong) NSTimer *reconnectTimer;
@property (nonatomic, strong) NSTimer *identifyTimer;
@property (nonatomic, strong) NSTimer *handshakeTimer;
@property (nonatomic) NSTimeInterval heartbeatInterval;
@property (nonatomic) NSTimeInterval nextIdentifyTime;
@property (nonatomic) BOOL awaitingHeartbeatAck;
@property (nonatomic) BOOL authenticationBlocked;
@property (nonatomic) NSUInteger reconnectAttempts;
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

- (instancetype)init {
    if ((self = [super init])) {
        _gatewayURL = DCDefaultGateway;
        _state = DCConnectionStateDisconnected;
    }
    return self;
}

- (void)clearSession {
    self.sessionId = nil;
    self.sequenceNumber = nil;
    self.resumeGatewayURL = nil;
}

- (void)startCommunicator {
    if (!self.Active || self.authenticationBlocked || self.websocket) return;
    if (![UserPreferences.sharedInstance valOfToken].length) return;
    if (!self.session) {
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 30;
        configuration.URLCache = nil;
        // Foundation performs normal system TLS trust evaluation. No custom trust overrides.
        self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:NSOperationQueue.mainQueue];
    }
    NSString *address = (self.sessionId.length && self.sequenceNumber && self.resumeGatewayURL.length)
        ? self.resumeGatewayURL : self.gatewayURL;
    NSURL *url = [NSURL URLWithString:address];
    if (![url.scheme.lowercaseString isEqualToString:@"wss"]) return;
    self.state = DCConnectionStateConnecting;
    self.websocket = [self.session webSocketTaskWithURL:url];
    self.websocket.maximumMessageSize = 16 * 1024 * 1024;
    [self.websocket resume];
    [self receiveFromTask:self.websocket];
    __weak typeof(self) weakSelf = self;
    self.handshakeTimer = [NSTimer scheduledTimerWithTimeInterval:45 repeats:NO block:^(NSTimer *timer) {
        [weakSelf reconnect];
    }];
}

- (void)receiveFromTask:(NSURLSessionWebSocketTask *)task {
    __weak typeof(self) weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self.websocket != task) return;
            if (error) {
                [self handleTransportFailure:task];
                return;
            }
            NSString *text = message.type == NSURLSessionWebSocketMessageTypeString ? message.string :
                [[NSString alloc] initWithData:message.data encoding:NSUTF8StringEncoding];
            if (text) [self processTextCallback:text];
            if (self.websocket == task) [self receiveFromTask:task];
        });
    }];
}

- (void)handleTransportFailure:(NSURLSessionWebSocketTask *)task {
    // Allow didCloseWithCode to deliver Discord's application close code first.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.websocket == task) [self processCloseCallback:task.closeCode message:nil];
    });
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task
 didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    if (self.websocket == task) [self processCloseCallback:closeCode message:nil];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (self.websocket == task) [self handleTransportFailure:(NSURLSessionWebSocketTask *)task];
}

- (void)processCloseCallback:(NSUInteger)code message:(NSString *)message {
    if (!self.Active || self.state == DCConnectionStateReconnecting) return;
    [Logger Log:[NSString stringWithFormat:@"Gateway closed (%lu)", (unsigned long)code]];
    // Authentication/protocol errors require a settings change, not an endless retry loop.
    if (code == 4004 || code == 4010 || code == 4011 || code == 4012 || code == 4013 || code == 4014) {
        self.authenticationBlocked = YES;
        [self clearSession];
        [self sleep:nil];
        [Logger Log:@"Gateway authentication or configuration rejected; update settings before retrying."];
        return;
    }
    if (code == 4007 || code == 4009 || code == 1000 || code == 1001) [self clearSession];
    [self reconnect];
}

- (void)processTextCallback:(NSString *)response {
    NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![object isKindOfClass:NSDictionary.class] || ![object[@"op"] isKindOfClass:NSNumber.class]) return;
    NSDictionary *payload = object;
    id value = payload[@"d"];
    NSDictionary *details = [value isKindOfClass:NSDictionary.class] ? value : @{};
    switch ([payload[@"op"] integerValue]) {
        case 10: {
            if (self.state != DCConnectionStateConnecting) return;
            id interval = details[@"heartbeat_interval"];
            if (![interval isKindOfClass:NSNumber.class] || !isfinite([interval doubleValue]) || [interval doubleValue] < 1000) {
                [self reconnect];
                return;
            }
            self.heartbeatInterval = [interval doubleValue] / 1000.0;
            self.awaitingHeartbeatAck = NO;
            [self scheduleHeartbeat:self.heartbeatInterval * ((double)arc4random_uniform(1000000) / 1000000.0)];
            self.state = DCConnectionStateIdentifying;
            if (self.sessionId.length && self.sequenceNumber) [self sendResume];
            else [self sendIdentify:details];
            break;
        }
        case 0: {
            if ([payload[@"s"] isKindOfClass:NSNumber.class]) self.sequenceNumber = payload[@"s"];
            NSString *event = [payload[@"t"] isKindOfClass:NSString.class] ? payload[@"t"] : nil;
            if ([event isEqualToString:@"READY"]) {
                if (![details[@"session_id"] isKindOfClass:NSString.class] || ![details[@"session_id"] length]) {
                    [self forceReconnect];
                    return;
                }
                self.sessionId = details[@"session_id"];
                NSString *resume = [details[@"resume_gateway_url"] isKindOfClass:NSString.class] ? details[@"resume_gateway_url"] : nil;
                NSURLComponents *components = resume ? [NSURLComponents componentsWithString:resume] : nil;
                NSString *host = components.host.lowercaseString;
                // Do not send credentials to an arbitrary URL supplied in a malformed event.
                if ([components.scheme.lowercaseString isEqualToString:@"wss"] &&
                    ([host isEqualToString:@"discord.gg"] || [host hasSuffix:@".discord.gg"])) {
                    components.query = @"v=10&encoding=json";
                    components.user = nil;
                    components.password = nil;
                    self.resumeGatewayURL = components.URL.absoluteString;
                } else self.resumeGatewayURL = nil;
            }
            if ([event isEqualToString:@"READY"] || [event isEqualToString:@"RESUMED"]) {
                self.state = DCConnectionStateConnected;
                self.reconnectAttempts = 0;
                [self.handshakeTimer invalidate];
                self.handshakeTimer = nil;
                [NSNotificationCenter.defaultCenter postNotificationName:@"connected" object:self];
            }
            break;
        }
        case 1: // Server-requested heartbeats do not reset the regular schedule.
            [self transmitHeartbeat];
            break;
        case 7:
            [self reconnect];
            break;
        case 9:
            if (![value isKindOfClass:NSNumber.class] || ![value boolValue]) [self clearSession];
            [self reconnectWithMinimumDelay:1.0 + arc4random_uniform(4000) / 1000.0];
            break;
        case 11:
            self.awaitingHeartbeatAck = NO;
            break;
        default:
            break;
    }
}

- (void)sendResume {
    NSString *token = [UserPreferences.sharedInstance valOfToken];
    if (!token.length || !self.sessionId.length || !self.sequenceNumber) return;
    [self sendJSON:@{@"op": @6, @"d": @{@"token": token, @"session_id": self.sessionId, @"seq": self.sequenceNumber}}];
}

- (void)sendIdentify:(NSDictionary *)hello {
    NSTimeInterval delay = self.nextIdentifyTime - NSProcessInfo.processInfo.systemUptime;
    if (delay > 0) {
        [self.identifyTimer invalidate];
        __weak typeof(self) weakSelf = self;
        self.identifyTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
            [weakSelf sendIdentify:nil];
        }];
        return;
    }
    NSString *token = [UserPreferences.sharedInstance valOfToken];
    if (!token.length || !self.Active) return;
    self.nextIdentifyTime = NSProcessInfo.processInfo.systemUptime + 5.5;
    [self sendJSON:@{@"op": @2, @"d": @{
        @"token": token, @"intents": @0,
        @"properties": @{@"os": @"iOS", @"browser": @"iPresence", @"device": @"iPresence"},
        @"large_threshold": @50, @"compress": @NO
    }}];
}

- (void)scheduleHeartbeat:(NSTimeInterval)delay {
    [self.heartbeatTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:MAX(0.001, delay) repeats:NO block:^(NSTimer *timer) {
        [weakSelf sendHeartbeat:timer];
    }];
}

- (void)transmitHeartbeat {
    self.awaitingHeartbeatAck = YES;
    [self sendJSON:@{@"op": @1, @"d": self.sequenceNumber ?: NSNull.null}];
}

- (void)sendHeartbeat:(NSTimer *)timer {
    if (!self.Active || !self.websocket) return;
    if (self.awaitingHeartbeatAck) {
        [self reconnect];
        return;
    }
    [self transmitHeartbeat];
    [self scheduleHeartbeat:self.heartbeatInterval];
}

- (void)cancelConnectionWithCode:(NSURLSessionWebSocketCloseCode)code {
    [self.heartbeatTimer invalidate]; self.heartbeatTimer = nil;
    [self.identifyTimer invalidate]; self.identifyTimer = nil;
    [self.handshakeTimer invalidate]; self.handshakeTimer = nil;
    self.awaitingHeartbeatAck = NO;
    NSURLSessionWebSocketTask *task = self.websocket;
    self.websocket = nil; // Ignore asynchronous callbacks from the old task.
    [task cancelWithCloseCode:code reason:nil];
}

- (void)reconnectWithMinimumDelay:(NSTimeInterval)minimum {
    if (!self.Active || self.reconnectTimer) return;
    self.state = DCConnectionStateReconnecting;
    [NSNotificationCenter.defaultCenter postNotificationName:@"idle" object:self];
    // 1000/1001 invalidate the Discord session; 4000 permits resume.
    [self cancelConnectionWithCode:(NSURLSessionWebSocketCloseCode)4000];
    NSTimeInterval delay = MIN(60.0, 2.0 * pow(2.0, MIN(self.reconnectAttempts, 5UL)));
    self.reconnectAttempts++;
    delay = MAX(minimum, delay + arc4random_uniform(1000) / 1000.0);
    __weak typeof(self) weakSelf = self;
    self.reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        weakSelf.reconnectTimer = nil;
        [weakSelf startCommunicator];
    }];
}

- (void)reconnect { [self reconnectWithMinimumDelay:0]; }
- (void)forceReconnect { [self clearSession]; [self reconnect]; }

- (void)disconnect {
    [self.reconnectTimer invalidate]; self.reconnectTimer = nil;
    [self cancelConnectionWithCode:NSURLSessionWebSocketCloseCodeNormalClosure];
    [self clearSession];
}

- (void)sendActivityJson:(NSNotification *)notification {
    if (self.state != DCConnectionStateConnected) return;
    NSArray *activities = notification.userInfo.count ? @[notification.userInfo] : @[];
    [self sendJSON:@{@"op": @3, @"d": @{
        @"since": NSNull.null, @"activities": activities, @"status": @"idle", @"afk": @NO
    }}];
}

- (void)sendJSON:(NSDictionary *)dictionary {
    NSURLSessionWebSocketTask *task = self.websocket;
    if (!task || !self.Active || self.state == DCConnectionStateReconnecting) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:NULL];
    if (!data || data.length > 4096) return;
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    // Never log payloads: Identify and Resume contain the account credential.
    __weak typeof(self) weakSelf = self;
    [task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:json] completionHandler:^(NSError *error) {
        if (!error) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.websocket == task) [weakSelf handleTransportFailure:task];
        });
    }];
}

- (void)awake:(NSNotification *)notification {
    if (self.Active || self.authenticationBlocked || ![UserPreferences.sharedInstance valOfShowAsDiscordStatus] ||
        ![UserPreferences.sharedInstance valOfToken].length) return;
    self.Active = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:@"idle" object:self];
    [self startCommunicator];
}

- (void)sleep:(NSNotification *)notification {
    self.Active = NO;
    self.state = DCConnectionStateDisconnected;
    [self disconnect];
    [NSNotificationCenter.defaultCenter postNotificationName:@"disconnected" object:self];
}

- (void)settingsChanged:(NSNotification *)notification {
    self.authenticationBlocked = NO;
    self.reconnectAttempts = 0;
    [self sleep:nil];
}
@end
