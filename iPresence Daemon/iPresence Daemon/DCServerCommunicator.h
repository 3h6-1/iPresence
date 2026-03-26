//
//  DCServerCommunicator.m
//  iPresence-Daemon
//
//  Created by kainograze on 1/9/26.
//  Copyright (c) 2018 kainograze. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "WSWebSocket.h"
#import "Logger.h"
#import "UserPreferences.h"

@interface DCServerCommunicator : NSObject

@property (nonatomic) WSWebSocket* websocket;
@property (nonatomic) NSString* gatewayURL;

@property (nonatomic) NSString* snowflake;

typedef NS_ENUM(NSInteger, DCConnectionState)
{
    DCConnectionStateIdle,
    DCConnectionStateConnecting,
    DCConnectionStateIdentifying,
    DCConnectionStateConnected,
    DCConnectionStateReconnecting,
    DCConnectionStateDisconnected
};
@property (atomic) DCConnectionState state;

@property BOOL Active;

#pragma mark - Singleton

+ (DCServerCommunicator*) sharedInstance;

#pragma mark - Creates Websocket

- (void) startCommunicator;

#pragma mark - Process websocket callbacks

- (void) processCloseCallback: (NSUInteger) code message: (NSString*) message;
- (void) processTextCallback: (NSString*) response;

#pragma mark - Case Senders

- (void) sendResume;
- (void) sendIdentify: (NSDictionary*) d;

#pragma mark - Heartbeat sender

- (void) sendHeartbeat: (NSTimer*) t;
- (void) checkForRecievedHeartbeat;
- (void) resetHeartbeat;

#pragma mark - Identity timer

- (void) refreshIdentifyCooldown:(NSTimer *)timer;

#pragma mark - Connection handlers

- (void) reconnect;
- (void) disconnect;
- (void) forceReconnect;

#pragma mark - Sender

- (void) testActivityJson;
- (void) sendActivityJson: (NSNotification*) n;
- (void) sendJSON: (NSDictionary*)dictionary;

#pragma mark - sleep and awake handlers

- (void) awake: (NSNotification*) n;
- (void) sleep: (NSNotification*) n;

@end