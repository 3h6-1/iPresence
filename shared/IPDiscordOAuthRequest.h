#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const IPDiscordOAuthRequestErrorDomain;
typedef NS_ENUM(NSInteger, IPDiscordOAuthRequestErrorCode) {
    IPDiscordOAuthRequestErrorInvalidCallback = 1,
    IPDiscordOAuthRequestErrorStateMismatch = 2,
    IPDiscordOAuthRequestErrorDenied = 3,
    IPDiscordOAuthRequestErrorInvalidResponse = 4,
};

// One in-memory OAuth attempt. Never persist or log its state, verifier, or URLs.
@interface IPDiscordOAuthRequest : NSObject
+ (NSString *)applicationID;
+ (NSString *)redirectURI;
// Discord's minimum SDK scope bundle also grants friend/relationship features.
+ (NSString *)requiredScopes;
+ (BOOL)isCallbackURL:(NSURL *)URL;
- (nullable instancetype)init;
@property(nonatomic, copy, readonly) NSString *state;
@property(nonatomic, copy, readonly) NSString *verifier;
@property(nonatomic, copy, readonly) NSString *challenge;
@property(nonatomic, copy, readonly) NSURL *authorizationURL;
- (nullable NSString *)authorizationCodeFromURL:(NSURL *)URL
                                         error:(NSError * _Nullable * _Nullable)error;
- (nullable NSURLRequest *)tokenRequestForCode:(NSString *)code;
+ (nullable NSURLRequest *)revocationRequestForToken:(NSString *)token;
+ (nullable NSData *)formEncodedData:(NSDictionary<NSString *, NSString *> *)fields;
#if defined(IPDISCORD_OAUTH_REQUEST_TESTING)
+ (NSString *)challengeForVerifierForTesting:(NSString *)verifier;
#endif
@end

NS_ASSUME_NONNULL_END
