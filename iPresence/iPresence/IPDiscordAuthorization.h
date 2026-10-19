#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const IPDiscordAuthorizationStateDidChangeNotification;
// Foreground account authorization only. The daemon alone refreshes credentials
// and connects the Social SDK presence session.
@interface IPDiscordAuthorization : NSObject
+ (instancetype)sharedInstance;
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, readonly) BOOL canCancelSignIn;
@property(nonatomic, readonly, nullable) NSString *progressMessage;
- (void)cancelSignIn;
- (BOOL)handleOpenURL:(NSURL *)url;
- (void)signInWithCompletion:(void (^)(BOOL success, NSString *message))completion;
- (void)signInUsingBrowserWithCompletion:(void (^)(BOOL success, NSString *message))completion;
- (void)signOutWithCompletion:(void (^)(BOOL success, NSString *message))completion;
@end
NS_ASSUME_NONNULL_END
