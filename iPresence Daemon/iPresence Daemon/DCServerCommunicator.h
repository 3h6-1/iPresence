#import <Foundation/Foundation.h>
#import "DCDiscordSDK.h"

typedef NS_ENUM(NSInteger, DCConnectionState) {
    DCConnectionStateIdle,
    DCConnectionStateConnecting,
    DCConnectionStateConnected,
    DCConnectionStateReconnecting,
    DCConnectionStateDisconnected
};

// All state, SDK calls and completion callbacks are confined to the main queue.
@interface DCServerCommunicator : NSObject
@property (nonatomic) DCConnectionState state;
@property (nonatomic) BOOL Active;
+ (instancetype)sharedInstance;
- (instancetype)initWithTransport:(id<DCDiscordTransport>)transport;
- (void)startCommunicator;
- (void)serviceCredentials;
- (void)settingsChanged:(NSNotification *)notification;
- (void)disconnect;
- (void)sendActivityJson:(NSNotification *)notification;
- (void)awake:(NSNotification *)notification;
- (void)sleep:(NSNotification *)notification;
@end
