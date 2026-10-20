// Original project by kainograze. Updated by 3h6_1.
#import "IPDiscordOAuthRequest.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#include <string.h>

NSString *const IPDiscordOAuthRequestErrorDomain = @"com.kainograze.iPresence.OAuthRequest";

static NSString *Base64URL(NSData *data) {
    NSString *encoded = [data base64EncodedStringWithOptions:0];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [encoded stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

static NSString *RandomValue(void) {
    uint8_t bytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) {
        memset_s(bytes, sizeof(bytes), 0, sizeof(bytes));
        return nil;
    }
    NSString *value = Base64URL([NSData dataWithBytes:bytes length:sizeof(bytes)]);
    memset_s(bytes, sizeof(bytes), 0, sizeof(bytes));
    return value;
}

static NSString *Challenge(NSString *verifier) {
    NSData *data = [verifier dataUsingEncoding:NSASCIIStringEncoding];
    if (!data || data.length > UINT32_MAX) return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return Base64URL([NSData dataWithBytes:digest length:sizeof(digest)]);
}

static void SetError(NSError **error, IPDiscordOAuthRequestErrorCode code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:IPDiscordOAuthRequestErrorDomain code:code
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL NonemptyBoundedString(id value, NSUInteger maximum) {
    if (![value isKindOfClass:NSString.class] || [value length] == 0 || [value length] > maximum) return NO;
    return [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

static BOOL StateMatches(NSString *supplied, NSString *expected) {
    if (!NonemptyBoundedString(supplied, 128)) return NO;
    NSData *left = [supplied dataUsingEncoding:NSASCIIStringEncoding];
    NSData *right = [expected dataUsingEncoding:NSASCIIStringEncoding];
    if (!left || left.length != right.length) return NO;
    const uint8_t *leftBytes = left.bytes, *rightBytes = right.bytes;
    volatile uint8_t difference = 0;
    for (NSUInteger index = 0; index < right.length; index++) difference |= leftBytes[index] ^ rightBytes[index];
    return difference == 0;
}

static NSString *FormComponent(NSString *value) {
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes) return nil;
    NSMutableString *encoded = [NSMutableString new];
    const uint8_t *characters = bytes.bytes;
    for (NSUInteger index = 0; index < bytes.length; index++) {
        uint8_t character = characters[index];
        if ((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
            (character >= '0' && character <= '9') || character == '-' || character == '_' ||
            character == '.' || character == '*') {
            [encoded appendFormat:@"%c", character];
        } else if (character == ' ') {
            [encoded appendString:@"+"];
        } else {
            [encoded appendFormat:@"%%%02X", character];
        }
    }
    return encoded;
}

static NSURLRequest *FormRequest(NSString *URL, NSDictionary<NSString *, NSString *> *fields) {
    NSData *body = [IPDiscordOAuthRequest formEncodedData:fields];
    if (!body) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:URL]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    request.HTTPShouldHandleCookies = NO;
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
    return [request copy];
}

@implementation IPDiscordOAuthRequest
+ (NSString *)applicationID { return @"1561870047562043402"; }
+ (NSString *)redirectURI { return @"discord-1561870047562043402:/authorize/callback"; }
+ (NSString *)requiredScopes { return @"openid sdk.social_layer_presence"; }
+ (BOOL)isCallbackURL:(NSURL *)URL {
    if (![URL isKindOfClass:NSURL.class] || URL.baseURL) return NO;
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    NSURLComponents *expected = [NSURLComponents componentsWithString:self.redirectURI];
    // Compare the encoded path too: percent-encoded path aliases and URL authorities
    // are not the registered redirect, even when Foundation can normalize them.
    return components && [components.scheme isEqual:expected.scheme] && components.host == nil &&
        components.user == nil && components.password == nil && components.port == nil && components.fragment == nil &&
        [components.percentEncodedPath isEqual:expected.percentEncodedPath];
}

- (instancetype)init {
    if ((self = [super init])) {
        _state = RandomValue();
        _verifier = RandomValue();
        if (!_state || !_verifier) return nil;
        _challenge = Challenge(_verifier);
        if (!_challenge) return nil;
        NSURLComponents *components = [NSURLComponents componentsWithString:@"https://discord.com/oauth2/authorize"];
        NSDictionary *fields = @{
            @"client_id": self.class.applicationID,
            @"response_type": @"code",
            @"redirect_uri": self.class.redirectURI,
            @"scope": self.class.requiredScopes,
            @"state": _state,
            @"code_challenge": _challenge,
            @"code_challenge_method": @"S256",
            @"prompt": @"consent"
        };
        NSMutableArray *items = [NSMutableArray new];
        for (NSString *key in [fields.allKeys sortedArrayUsingSelector:@selector(compare:)])
            [items addObject:[NSURLQueryItem queryItemWithName:key value:fields[key]]];
        components.queryItems = items;
        _authorizationURL = components.URL;
        if (!_authorizationURL) return nil;
        // Match the official iOS Social SDK's native handoff. Discord's native
        // route uses code_method; the web OAuth endpoint uses code_challenge_method.
        NSURLComponents *native = [NSURLComponents componentsWithString:@"discord://view/oauth2/authorize"];
        NSMutableDictionary *nativeFields = [fields mutableCopy];
        [nativeFields removeObjectForKey:@"prompt"];
        [nativeFields removeObjectForKey:@"code_challenge_method"];
        nativeFields[@"code_method"] = @"S256";
        NSMutableArray *nativeItems = [NSMutableArray new];
        for (NSString *key in [nativeFields.allKeys sortedArrayUsingSelector:@selector(compare:)])
            [nativeItems addObject:[NSURLQueryItem queryItemWithName:key value:nativeFields[key]]];
        native.queryItems = nativeItems;
        _nativeAuthorizationURL = native.URL;
        if (!_nativeAuthorizationURL) return nil;
    }
    return self;
}

- (NSString *)authorizationCodeFromURL:(NSURL *)URL error:(NSError **)error {
    if (error) *error = nil;
    if (![self.class isCallbackURL:URL]) {
        SetError(error, IPDiscordOAuthRequestErrorInvalidCallback, @"Discord returned an invalid sign-in redirect.");
        return nil;
    }
    if (URL.absoluteString.length > 16384) {
        SetError(error, IPDiscordOAuthRequestErrorStateMismatch, @"The Discord sign-in response did not match this request. Try again.");
        return nil;
    }
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    NSMutableDictionary<NSString *, NSString *> *parameters = [NSMutableDictionary new];
    BOOL duplicateParameter = NO, duplicateState = NO;
    for (NSURLQueryItem *item in components.queryItems) {
        if (parameters[item.name]) {
            duplicateParameter = YES;
            if ([item.name isEqual:@"state"]) duplicateState = YES;
        }
        parameters[item.name] = item.value ?: @"";
    }
    // An unrelated app can open our URL scheme. Classify uncorrelated responses
    // before other errors, so a forged callback cannot cancel the active attempt.
    if (duplicateState || !StateMatches(parameters[@"state"], self.state)) {
        SetError(error, IPDiscordOAuthRequestErrorStateMismatch, @"The Discord sign-in response did not match this request. Try again.");
        return nil;
    }
    if (duplicateParameter) {
        SetError(error, IPDiscordOAuthRequestErrorInvalidResponse, @"Discord returned an ambiguous sign-in response.");
        return nil;
    }
    if (parameters[@"iss"] && ![parameters[@"iss"] isEqual:@"https://discord.com"]) {
        SetError(error, IPDiscordOAuthRequestErrorInvalidResponse, @"Discord returned an invalid authorization server.");
        return nil;
    }
    NSString *authorizationError = parameters[@"error"], *code = parameters[@"code"];
    if (authorizationError) {
        if (code || !authorizationError.length) {
            SetError(error, IPDiscordOAuthRequestErrorInvalidResponse, @"Discord returned an ambiguous sign-in response.");
        } else if ([authorizationError isEqual:@"access_denied"]) {
            SetError(error, IPDiscordOAuthRequestErrorDenied, @"Discord sign-in was cancelled.");
        } else {
            SetError(error, IPDiscordOAuthRequestErrorInvalidResponse, @"Discord did not authorize sign-in. Try again.");
        }
        return nil;
    }
    if (!NonemptyBoundedString(code, 4096)) {
        SetError(error, IPDiscordOAuthRequestErrorInvalidResponse, @"Discord returned an invalid authorization code.");
        return nil;
    }
    return code;
}

- (NSURLRequest *)tokenRequestForCode:(NSString *)code {
    if (!NonemptyBoundedString(code, 4096)) return nil;
    return FormRequest(@"https://discord.com/api/oauth2/token", @{
        @"client_id": self.class.applicationID,
        @"grant_type": @"authorization_code",
        @"code": code,
        @"code_verifier": self.verifier,
        @"redirect_uri": self.class.redirectURI
    });
}

+ (NSURLRequest *)revocationRequestForToken:(NSString *)token {
    if (!NonemptyBoundedString(token, 16384)) return nil;
    return FormRequest(@"https://discord.com/api/oauth2/token/revoke", @{
        @"client_id": self.applicationID,
        @"token": token,
        @"token_type_hint": @"refresh_token"
    });
}

+ (NSData *)formEncodedData:(NSDictionary<NSString *,NSString *> *)fields {
    if (![fields isKindOfClass:NSDictionary.class]) return nil;
    for (id key in fields) {
        if (![key isKindOfClass:NSString.class] || ![fields[key] isKindOfClass:NSString.class]) return nil;
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    for (NSString *key in [fields.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *encodedKey = FormComponent(key), *encodedValue = FormComponent(fields[key]);
        if (!encodedKey || !encodedValue) return nil;
        [parts addObject:[NSString stringWithFormat:@"%@=%@", encodedKey, encodedValue]];
    }
    return [[parts componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
}

#if defined(IPDISCORD_OAUTH_REQUEST_TESTING)
+ (NSString *)challengeForVerifierForTesting:(NSString *)verifier { return Challenge(verifier); }
#endif
@end
