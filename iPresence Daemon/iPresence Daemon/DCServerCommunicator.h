#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DCConnectionState) {
    DCConnectionStateIdle,
    DCConnectionStateConnecting,
    DCConnectionStateIdentifying,
    DCConnectionStateConnected,
    DCConnectionStateReconnecting,
    DCConnectionStateDisconnected
};

// All state and callbacks are confined to the main queue.
@interface DCServerCommunicator : NSObject <NSURLSessionWebSocketDelegate>
@property (nonatomic, strong) NSURLSessionWebSocketTask *websocket;
@property (nonatomic, copy) NSString *gatewayURL;
@property (nonatomic) DCConnectionState state;
@property (nonatomic) BOOL Active;
+ (instancetype)sharedInstance;
- (void)startCommunicator;
- (void)processTextCallback:(NSString *)response;
- (void)processCloseCallback:(NSUInteger)code message:(NSString *)message;
- (void)sendHeartbeat:(NSTimer *)timer;
- (void)sendResume;
- (void)sendIdentify:(NSDictionary *)hello;
- (void)reconnect;
- (void)forceReconnect;
- (void)disconnect;
- (void)sendActivityJson:(NSNotification *)notification;
- (void)sendJSON:(NSDictionary *)dictionary;
- (void)awake:(NSNotification *)notification;
- (void)sleep:(NSNotification *)notification;
@end
