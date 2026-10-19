#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const IPOAuthStoreErrorDomain;
typedef NS_ENUM(NSInteger, IPOAuthStoreErrorCode) {
    IPOAuthStoreErrorInvalidCredentials = 1,
    IPOAuthStoreErrorUnsafeFile,
    IPOAuthStoreErrorIO,
    IPOAuthStoreErrorSessionMismatch,
};

// Shared by the mobile-user app and daemon. These OAuth credentials are private
// to that Unix user; a privileged process on a jailbroken device can still read them.
@interface IPOAuthStore : NSObject
+ (nullable NSDictionary<NSString *, id> *)credentials;
// nil starts a new login. A nonnil session atomically rejects a stale refresh.
// Notification is deliberately separate: a daemon refresh must not restart itself.
+ (BOOL)saveCredentials:(NSDictionary<NSString *, id> *)credentials
       replacingSession:(nullable NSString *)sessionID
                  error:(NSError * _Nullable * _Nullable)error;
+ (void)clearCredentials;
// Use the reporting form when confirming logout; a failed read does not prove deletion.
+ (BOOL)clearCredentialsWithError:(NSError * _Nullable * _Nullable)error;
+ (BOOL)clearCredentialsIfSessionMatches:(NSString *)sessionID;
+ (void)notifyChanged;
#if defined(IPOAUTH_STORE_TESTING)
// Compiled out of production. Tests must supply an existing private directory.
+ (void)setDirectoryForTesting:(NSString *)directory;
#endif
@end

NS_ASSUME_NONNULL_END
