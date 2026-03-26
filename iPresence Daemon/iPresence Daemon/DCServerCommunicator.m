//
//  DCServerCommunicator.m
//  iPresence-Daemon
//
//  Created by kainograze on 1/9/26.
//  Copyright (c) 2018 kainograze. All rights reserved.
//

// Special thanks to Dicord Classic

#import "DCServerCommunicator.h"
#import "Tools.h"

@interface DCServerCommunicator ()
@property BOOL didRecieveHeartbeatResponse;
@property BOOL shouldResume;
@property BOOL heartbeatDefined;

@property BOOL identifyCooldownActive;
@property BOOL forcingReconnect;

@property int sequenceNumber;
@property (nonatomic, strong) NSString *sessionId;

@property (nonatomic, strong) NSTimer *cooldownTimer;
@property (nonatomic, strong) NSTimer *heartbeatTimer;
@property (nonatomic, strong) NSTimer* heartbeatAckTimer;

@property int reconnectAttempts;

+ (DCServerCommunicator *) sharedInstance;

@end

@implementation DCServerCommunicator

+ (DCServerCommunicator *) sharedInstance
{
    
    static DCServerCommunicator *sharedInstance = nil;
    
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
        
        // Initialize if a sharedInstance does not yet exist
        
        [NSNotificationCenter.defaultCenter addObserver:sharedInstance selector:@selector(awake:) name:@"awake" object:nil];
        
        [NSNotificationCenter.defaultCenter addObserver:sharedInstance selector:@selector(sleep:) name:@"sleep" object:nil];
        
        [NSNotificationCenter.defaultCenter addObserver:sharedInstance selector:@selector(sendActivityJson:) name:@"sendActivityJson" object:nil];
        
        sharedInstance.gatewayURL = @"wss://gateway.discord.gg/?encoding=json&v=9";
        
        sharedInstance.state = DCConnectionStateDisconnected;
        sharedInstance.heartbeatDefined = NO;
        sharedInstance.Active = NO;
        sharedInstance.reconnectAttempts = 0;
        sharedInstance.forcingReconnect = NO;
    });
    
    return sharedInstance;
}

#pragma mark - Creates websocket

- (void)startCommunicator
{
    if (!self.Active) return;
    if (self.state != DCConnectionStateReconnecting && self.state != DCConnectionStateDisconnected) return;
    
    NSLog(@"starting communicator");
    
    NSURL *websocketUrl = [NSURL URLWithString:self.gatewayURL];
    self.websocket = [WSWebSocket.alloc initWithURL:websocketUrl protocols:nil];
    __weak typeof(self) weakSelf = self;
    
    self.state = DCConnectionStateConnecting;
    
    [self.websocket setTextCallback:^(NSString *responseString) {
        //dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf processTextCallback:responseString];
        //});
    }];
    
    [self.websocket setCloseCallback: ^(NSUInteger code, NSString* message) {
        [weakSelf processCloseCallback:code message:message];
    }];
    
    [self.websocket open];
    
}

#pragma mark - Process websocket callbacks

- (void) processCloseCallback:(NSUInteger)code message:(NSString *)message
{
    [Logger Log:[NSString stringWithFormat:@"Websocket is closing with code %i and message %@", code, message]];
    
    if (self.state == DCConnectionStateDisconnected || self.state == DCConnectionStateReconnecting)
        return;
    
    NSLog(@"websocket closed unexpectedly, reconnecting");
    [self reconnect];
}

- (void) processTextCallback: (NSString*)responseString
{
    // Parse JSON to a dictionary
    NSDictionary *parsedJsonResponse = [Tools parseJSON:responseString];
    
    // Data values for easy access
    int op = [[parsedJsonResponse valueForKey:@"op"] integerValue];
    
    [Logger Log:[NSString stringWithFormat:@"Got op code %i", op]];
    
    switch (op)
    {
        case 10:
        {
            if (self.shouldResume)
            {
                [Logger Log:[NSString stringWithFormat:@"Sending Resume with sequence "
                             @"number %i, session ID %@",
                             self.sequenceNumber,
                             self.sessionId]];
                [self sendResume];
                self.shouldResume = NO;
            }
            else
            {
                [Logger Log:@"Sending Identify"];
                
                NSDictionary *d = [parsedJsonResponse valueForKey:@"d"];
                self.state = DCConnectionStateIdentifying;
                [self sendIdentify: d];
            }
        }
            break;
            
        case 0:
        {
            NSString* t = [parsedJsonResponse valueForKey:@"t"];
            self.sequenceNumber = [[parsedJsonResponse valueForKey:@"s"] integerValue];
            
            [Logger Log:[NSString stringWithFormat:@"Got event %@ with sequence number %i",t, self.sequenceNumber]];
            
            if ([t isEqualToString: @"READY"])
            {
                NSDictionary *d = [parsedJsonResponse valueForKey:@"d"];
                self.sessionId = [NSString stringWithFormat:@"%@", [d valueForKeyPath:@"session_id"]];
                self.state = DCConnectionStateConnected;
                self.reconnectAttempts = 0;
                self.forcingReconnect = NO;
                
                dispatch_async(dispatch_get_main_queue(),^{
                    [NSNotificationCenter.defaultCenter postNotificationName:@"connected" object:self];
                });
                //[self testActivityJson];
            }
            else if ([t isEqualToString: @"RESUMED"])
            {
                self.state = DCConnectionStateConnected;
                self.reconnectAttempts = 0;
                self.forcingReconnect = NO;
                
                dispatch_async(dispatch_get_main_queue(),^{
                    [NSNotificationCenter.defaultCenter postNotificationName:@"connected" object:self];
                });

            }
        }
            break;
            
        case 11:
        {
            [Logger Log:@"Got Heartbeat response"];
            self.didRecieveHeartbeatResponse = true;
            [self.heartbeatAckTimer invalidate];
            self.heartbeatAckTimer = nil;
        }
            break;
            
        case 9:
        {
            [Logger Log: @"Discord requested a reconnect for invalid session"];
            [self forceReconnect];
        }
            break;
            
        default:
        {
            // we don't need to handle any other op as this is a minimal client
        }
            break;
    }
}

#pragma mark - Case Senders

- (void)sendResume
{
    [self sendJSON:
     @{
       @"op" : @6,
       @"d" :
           @{
               @"token" : [UserPreferences.sharedInstance valOfToken],
               @"session_id" : self.sessionId,
               @"seq" : @(self.sequenceNumber),
               }
       }];
}

- (void)sendIdentify: (NSDictionary*) d
{
    // IDENTIFY
    [self sendJSON:
     @{
       @"op" : @2,
       @"d" :
           @{
               @"token" : [UserPreferences.sharedInstance valOfToken],
               @"properties" :
                   @{
                       @"os" : @"iOS",
                       @"$browser" : @"Discord iOS",
                       },
               @"large_threshold" : @"50",
               }
       }];
    
    // Disable ability to identify until reenabled 5 seconds later.
    // API only allows once identify every 5 seconds
    self.identifyCooldownActive = YES;
    
    // initial value should be true
    self.didRecieveHeartbeatResponse = YES;
    
    int heartbeatInterval = [[d valueForKey:@"heartbeat_interval"] intValue];
    
    [Logger Log:[NSString stringWithFormat:@"Heartbeat is %d seconds",
                 heartbeatInterval / 1000]];
    
    if (!self.heartbeatDefined)
    {
        [Logger Log:@"Setting Heartbeat timer"];
        
        // the intention is to consume the least resources. making it run on the main
        // thread is ideal instead of making it run on its own loop.
        dispatch_async(dispatch_get_main_queue(), ^{
            self.heartbeatTimer =
            [NSTimer scheduledTimerWithTimeInterval:heartbeatInterval / 1000
                                             target:self
                                           selector:@selector(sendHeartbeat:)
                                           userInfo:nil
                                            repeats:YES];
            self.heartbeatDefined = YES;
        });
    }
    
    if (!self.cooldownTimer)
    {
        dispatch_async(dispatch_get_main_queue(),^{
            self.cooldownTimer =
            [NSTimer scheduledTimerWithTimeInterval:5
                                             target:self
                                           selector:@selector(refreshIdentifyCooldown:)
                                           userInfo:nil
                                            repeats:NO];
            self.identifyCooldownActive = YES;
        });
    }
}

#pragma mark - Heartbeat sender

- (void) sendHeartbeat: (NSTimer*) t
{
    [Logger Log:@"send heartbeat called"];
    
    if (!self.websocket)
    {
        [Logger Log:@"Wont send heartbeat because websocket isnt valid"];
        return;
    }
    
    if (self.state == DCConnectionStateDisconnected ||
        self.state == DCConnectionStateReconnecting)
        return;
    
    self.didRecieveHeartbeatResponse = NO;
    
    if (!self.heartbeatAckTimer)
        dispatch_async(dispatch_get_main_queue(), ^{
            self. heartbeatAckTimer = [NSTimer scheduledTimerWithTimeInterval:8 target:self selector:@selector(checkForRecievedHeartbeat) userInfo:nil repeats:NO];
        });
    
    [self sendJSON:@{ @"op": @1, @"d": @(self.sequenceNumber)}];
    [Logger Log:@"Sent heartbeat"];
    
}

- (void) checkForRecievedHeartbeat
{
    [self.heartbeatAckTimer invalidate];
    self.heartbeatAckTimer = nil;
    
    if (self.didRecieveHeartbeatResponse) return;
    
    [self reconnect];
}

- (void) resetHeartbeat
{
    [self.heartbeatTimer invalidate];
    self.heartbeatTimer = nil;
    self.heartbeatDefined = NO;
    [self.heartbeatAckTimer invalidate];
    self.heartbeatAckTimer = nil;
}

#pragma mark - Identity timer

- (void)refreshIdentifyCooldown:(NSTimer *)timer
{
    self.identifyCooldownActive = NO;
    
    [self.cooldownTimer invalidate];
    self.cooldownTimer = nil;
    
    [Logger Log:@"Authentication cooldown ended"];
}

#pragma mark - Connection handlers

/*
 The prime difference between forceReconnect and reconnect is that forceReconnect forces a new
 session, while reconnect will try to resume.
 Therefore, reconnect should always be the method called when wanting to reopen the websocket,
 because if the session is invalid, discord will throw op case 9, which will trigger a
 forceReconnect to generate a new, valid session.
 This prime difference should always be taken into account in states: reconnect will set the state
 to resumming, while forceReconnect will set it to reconnecting.
 */

- (void) reconnect
{
    [Logger Log:[NSString stringWithFormat:@"Identify cooldown %s", self.identifyCooldownActive ? "true" : "false"]];
    
    self.state = DCConnectionStateReconnecting;
    
    dispatch_async(dispatch_get_main_queue(),^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"idle" object:self];
    });
    
    [self disconnect];
    
    NSTimeInterval delay = [self nextReconnectDelay];
    self.reconnectAttempts++;
    NSLog(@"attemping to reconnect, attempt number: %i", self.reconnectAttempts);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self reconnectRoutine];
    });
}

- (void) forceReconnect
{
    NSLog(@"force reconnect");
    self.forcingReconnect = YES;
    self.shouldResume = NO;
    
    self.sequenceNumber = 0;
    self.sessionId = nil;
    
    [self reconnect];
}

- (void) reconnectRoutine
{
    NSLog(@"reconnecting");
    if (!self.forcingReconnect) self.shouldResume = YES;
    
    if(!self.identifyCooldownActive)
    {
        [Logger Log:@"No cooldown in effect. Authenticating..."];
        [self startCommunicator];
    }
    else
    {
        double timeRemaining = self.cooldownTimer.fireDate.timeIntervalSinceNow;
        
        [Logger Log:[NSString stringWithFormat:@"Cooldown in effect. Time left %f", timeRemaining]];
        
        [self performSelector:@selector(startCommunicator) withObject:nil afterDelay:timeRemaining + 1];
    }
}

- (void) disconnect
{
    // notice how this method doesn't reset the session. forceReconnect should be the only place
    // where that happens.
    
    [Logger Log:@"Disconnecting websocket"];
    
    // cooldownTimer should not be invalidated here
    [self resetHeartbeat];
    
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    
    // reset state
    self.didRecieveHeartbeatResponse = NO;
    
    // close websocket
    if (self.websocket)
    {
        [self.websocket close];
        self.websocket = nil;
    }
}

- (NSTimeInterval)nextReconnectDelay
{
    int attempt = self.reconnectAttempts;
    NSTimeInterval delay = pow(2, attempt) * 2;
    return MIN(delay, 60);
}

#pragma mark - Senders

- (void) testActivityJson
{
    NSTimeInterval timeSince = [NSDate.date timeIntervalSince1970];
    long long totalPlayback = (timeSince * 1000) + (120 * 1000);
    long long current = timeSince * 1000;

    
    [Logger Log:@"sending test activity json"];
    NSDictionary* jsonToSend =
    @{
      @"op": @3,
      @"d":
          @{
              @"since": [NSNull null],
              @"activities":
              @[@{
                      @"application_id":@"1460106321427955903",
                      @"name": @"test hihi",
                      @"type": @2,
                      @"state": @"artist",
                      @"details": @"song",
                      @"assets":
                      @{
                          @"large_image": @"https://mondiniplantas.cdn.magazord.com.br/img/2025/09/produto/7521/banana-caturra-nanica.jpg?ims=800x800",
                          @"large_text": @"bleh"
                      },
                      @"timestamps":
                      @{
                              @"start": [NSNumber numberWithLongLong:current],
                              @"end": [NSNumber numberWithLongLong:totalPlayback]
                        }
              }],
              @"status": [NSNull null],
              @"afk": @NO
              }
      };
    
    [self sendJSON: jsonToSend];
}

- (void)sendActivityJson: (NSNotification*) n
{
    [Logger Log: @"received activity json thru notification, trying to send. state: "];
    
    NSDictionary* jsonToSend =
    @{
      @"op": @3,
      @"d":
          @{
              @"since": [NSNull null],
              @"activities": n.userInfo ? @[n.userInfo] : [NSNull null],
              @"status": @"idle",
              @"afk": @NO
              }
      };
    
    if (self.state == DCConnectionStateConnected) [self sendJSON: jsonToSend];
    
}

- (void)sendJSON:(NSDictionary*)dictionary
{
    
    if (!self.websocket) return;
    
    if (self.state == DCConnectionStateDisconnected ||
        self.state == DCConnectionStateReconnecting)
        return;
    
    [Logger Log:@"trying to send json"];
    
    NSError *writeError = nil;
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:&writeError];
    
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    [Logger Log: jsonString];
    [self.websocket sendText:jsonString];
    
}

#pragma mark - Sleep and awake routines

- (void) awake:(NSNotification *)n
{
    NSLog(@"DC attempting to awake");
    if (![UserPreferences.sharedInstance valOfShowAsDiscordStatus]) return;
    if (![UserPreferences.sharedInstance valOfToken]) return;
    
    NSLog(@"awakening");
    
    self.Active = YES;
    if (self.sessionId) [self reconnect];
    else
    {
        NSLog(@"no session id found, starting new session");
        [self startCommunicator];
    }
    dispatch_async(dispatch_get_main_queue(),^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"idle" object:self];
    });
}

- (void) sleep:(NSNotification *)n
{
    NSLog(@"DC sleep");
    // the only place where the state should be set to disconnected. the websocket should always
    // try to reconnect in any other case.
    dispatch_async(dispatch_get_main_queue(),^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"disconnected" object:self];
    });
    self.Active = NO;
    self.state = DCConnectionStateDisconnected;
    [self disconnect];
}

@end