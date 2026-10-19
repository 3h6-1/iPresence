#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Foreground account authorization only. The daemon alone refreshes credentials
// and connects the Social SDK presence session.
@interface IPDiscordAuthorization : NSObject
+ (instancetype)sharedInstance;
@property(nonatomic, readonly) BOOL busy;
- (void)signInWithCompletion:(void (^)(BOOL success, NSString *message))completion;
- (void)signOutWithCompletion:(void (^)(BOOL success, NSString *message))completion;
@end
NS_ASSUME_NONNULL_END
