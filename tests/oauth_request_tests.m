#import <Foundation/Foundation.h>
#import "IPDiscordOAuthRequest.h"

static NSUInteger checks;
#define CHECK(condition, message) do { checks++; if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); exit(1); } } while (0)

static NSURL *Callback(NSString *query) {
    return [NSURL URLWithString:[IPDiscordOAuthRequest.redirectURI stringByAppendingFormat:@"?%@", query]];
}

static NSDictionary *Query(NSURL *URL) {
    NSMutableDictionary *values = [NSMutableDictionary new];
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO].queryItems)
        values[item.name] = item.value ?: @"";
    return values;
}

static NSString *Body(NSURLRequest *request) {
    return [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
}

int main(void) {
    @autoreleasepool {
        IPDiscordOAuthRequest *request = [IPDiscordOAuthRequest new];
        IPDiscordOAuthRequest *second = [IPDiscordOAuthRequest new];
        CHECK(request != nil && second != nil, "Secure randomness initializes OAuth attempts");
        CHECK(request.state.length == 43 && request.verifier.length == 43 && request.challenge.length == 43,
              "PKCE and state use full unpadded 256-bit values");
        CHECK(![request.state isEqual:second.state] && ![request.verifier isEqual:second.verifier] &&
              ![request.state isEqual:request.verifier], "Attempts have independent state and verifiers");
        NSCharacterSet *outsideBase64URL = [[NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"] invertedSet];
        CHECK([request.state rangeOfCharacterFromSet:outsideBase64URL].location == NSNotFound &&
              [request.verifier rangeOfCharacterFromSet:outsideBase64URL].location == NSNotFound &&
              [request.challenge rangeOfCharacterFromSet:outsideBase64URL].location == NSNotFound,
              "Cryptographic values contain only base64url characters");
        CHECK([[IPDiscordOAuthRequest challengeForVerifierForTesting:@"dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"]
                isEqual:@"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"], "PKCE matches RFC7636 SHA256 example");

        NSURLComponents *authorize = [NSURLComponents componentsWithURL:request.authorizationURL resolvingAgainstBaseURL:NO];
        NSDictionary *fields = Query(request.authorizationURL);
        CHECK([authorize.scheme isEqual:@"https"] && [authorize.host isEqual:@"discord.com"] &&
              [authorize.path isEqual:@"/oauth2/authorize"], "Authorization stays on Discord HTTPS endpoint");
        CHECK(fields.count == 8 && [fields[@"client_id"] isEqual:@"1561870047562043402"] &&
              [fields[@"response_type"] isEqual:@"code"] && [fields[@"prompt"] isEqual:@"consent"],
              "Authorization uses explicit public-client code grant");
        CHECK([fields[@"redirect_uri"] isEqual:IPDiscordOAuthRequest.redirectURI] &&
              [fields[@"state"] isEqual:request.state] && [fields[@"code_challenge"] isEqual:request.challenge] &&
              [fields[@"code_challenge_method"] isEqual:@"S256"], "Authorization binds redirect, state, and PKCE");
        CHECK([fields[@"scope"] isEqual:@"openid sdk.social_layer_presence"], "Only documented minimum SDK bundle is requested");
        CHECK(![request.authorizationURL.absoluteString containsString:request.verifier], "Verifier never enters authorization URL");

        NSURLComponents *native = [NSURLComponents componentsWithURL:request.nativeAuthorizationURL resolvingAgainstBaseURL:NO];
        NSDictionary *nativeFields = Query(request.nativeAuthorizationURL);
        CHECK([native.scheme isEqual:@"discord"] && [native.host isEqual:@"view"] &&
              [native.path isEqual:@"/oauth2/authorize"], "Native handoff uses the official SDK's captured Discord route");
        CHECK(nativeFields.count == 7 && [nativeFields[@"client_id"] isEqual:fields[@"client_id"]] &&
              [nativeFields[@"response_type"] isEqual:@"code"] && [nativeFields[@"scope"] isEqual:fields[@"scope"]] &&
              [nativeFields[@"state"] isEqual:request.state] && [nativeFields[@"redirect_uri"] isEqual:fields[@"redirect_uri"]],
              "Native handoff preserves the same attempt, scopes, and registered redirect");
        CHECK([nativeFields[@"code_method"] isEqual:@"S256"] && [nativeFields[@"code_challenge"] isEqual:request.challenge] &&
              nativeFields[@"code_challenge_method"] == nil && nativeFields[@"prompt"] == nil,
              "Native PKCE parameter names match the official SDK's captured seven-field request");
        CHECK(![request.nativeAuthorizationURL.absoluteString containsString:request.verifier],
              "Native handoff never exposes the private verifier");

        NSError *error = [NSError errorWithDomain:@"old" code:1 userInfo:nil];
        NSString *validQuery = [NSString stringWithFormat:@"code=good-code&state=%@", request.state];
        NSURL *callback = Callback(validQuery);
        CHECK([IPDiscordOAuthRequest isCallbackURL:callback], "Registered callback identity accepted");
        CHECK([[request authorizationCodeFromURL:callback error:&error] isEqual:@"good-code"] && error == nil,
              "Valid matching callback returns code and clears old errors");
        CHECK([[request authorizationCodeFromURL:Callback([validQuery stringByAppendingString:@"&iss=https%3A%2F%2Fdiscord.com"])
            error:&error] isEqual:@"good-code"], "Expected Discord issuer accepted");
        CHECK([[request authorizationCodeFromURL:Callback([NSString stringWithFormat:@"code=code%%2Bplus%%26amp%%3Dequals&state=%@", request.state])
            error:&error] isEqual:@"code+plus&amp=equals"], "Encoded authorization code survives parsing");

        NSArray<NSString *> *wrongRedirects = @[
            @"discord-1561870047562043403:/authorize/callback",
            @"DISCORD-1561870047562043402:/authorize/callback",
            @"https://discord.com/authorize/callback",
            @"discord-1561870047562043402://evil.example/authorize/callback",
            @"discord-1561870047562043402:///authorize/callback",
            @"discord-1561870047562043402://user:password@evil.example:443/authorize/callback",
            @"discord-1561870047562043402:/authorize/callback/",
            @"discord-1561870047562043402:/authorize/%63allback",
            @"discord-1561870047562043402:/authorize/../authorize/callback",
            @"discord-1561870047562043402:/authorize/callback#",
            @"discord-1561870047562043402:/authorize/callback#fragment"
        ];
        for (NSString *redirect in wrongRedirects) {
            NSURL *wrong = [NSURL URLWithString:[redirect stringByAppendingFormat:@"?%@", validQuery]];
            CHECK(![IPDiscordOAuthRequest isCallbackURL:wrong], "Unregistered redirect identity rejected");
            CHECK([request authorizationCodeFromURL:wrong error:&error] == nil &&
                  error.code == IPDiscordOAuthRequestErrorInvalidCallback, "Wrong redirect cannot deliver a code");
        }
        NSURL *relative = [NSURL URLWithString:@"?code=good-code" relativeToURL:[NSURL URLWithString:IPDiscordOAuthRequest.redirectURI]];
        CHECK(![IPDiscordOAuthRequest isCallbackURL:relative], "Relative callback cannot inherit trusted base URL");

        for (NSString *query in @[@"code=good-code", @"code=good-code&state=", @"code=good-code&state=forged",
                                 @"code=good-code&state=%00", @"code=good-code&state=%F0%9F%98%80"]) {
            CHECK([request authorizationCodeFromURL:Callback(query) error:&error] == nil &&
                  error.code == IPDiscordOAuthRequestErrorStateMismatch, "Missing or forged state rejected");
        }
        CHECK([request authorizationCodeFromURL:Callback([NSString stringWithFormat:@"code=good-code&state=%@", second.state]) error:&error] == nil,
              "Another attempt's state cannot finish this attempt");
        CHECK([request authorizationCodeFromURL:Callback([validQuery stringByAppendingFormat:@"&state=%@", request.state]) error:&error] == nil &&
              error.code == IPDiscordOAuthRequestErrorStateMismatch, "Duplicate state never authenticates a callback");
        CHECK([request authorizationCodeFromURL:Callback(@"code=one&code=two&state=forged") error:&error] == nil &&
              error.code == IPDiscordOAuthRequestErrorStateMismatch, "Forged malformed callback cannot cancel an active attempt");
        NSString *oversized = [@"x" stringByPaddingToLength:17000 withString:@"x" startingAtIndex:0];
        CHECK([request authorizationCodeFromURL:Callback([@"code=" stringByAppendingString:oversized]) error:&error] == nil &&
              error.code == IPDiscordOAuthRequestErrorStateMismatch, "Oversized uncorrelated callback cannot cancel an active attempt");
        NSArray<NSString *> *ambiguousQueries = @[
            [validQuery stringByAppendingString:@"&code=other"],
            [validQuery stringByAppendingString:@"&%63ode=other"],
            [validQuery stringByAppendingString:@"&error=access_denied"],
            [validQuery stringByAppendingString:@"&iss=https%3A%2F%2Fevil.example"],
            [validQuery stringByAppendingString:@"&iss=https%3A%2F%2Fdiscord.com&iss=https%3A%2F%2Fdiscord.com"],
            [NSString stringWithFormat:@"state=%@&error=access_denied&error=access_denied", request.state],
            [NSString stringWithFormat:@"state=%@&code=", request.state],
            [NSString stringWithFormat:@"state=%@&code=%%00", request.state],
            [NSString stringWithFormat:@"state=%@", request.state]
        ];
        for (NSString *query in ambiguousQueries) {
            CHECK([request authorizationCodeFromURL:Callback(query) error:&error] == nil &&
                  error.code == IPDiscordOAuthRequestErrorInvalidResponse, "Ambiguous or malformed auth response rejected");
        }
        CHECK([request authorizationCodeFromURL:Callback([NSString stringWithFormat:
            @"state=%@&error=access_denied&error_description=DO-NOT-DISPLAY-THIS-SECRET", request.state]) error:&error] == nil &&
            error.code == IPDiscordOAuthRequestErrorDenied && [error.localizedDescription isEqual:@"Discord sign-in was cancelled."] &&
            ![error.description containsString:@"DO-NOT-DISPLAY"], "Consent denial is sanitized without reflecting provider error details");

        NSData *encoded = [IPDiscordOAuthRequest formEncodedData:@{@"key +&=": @"a+b c&d=e/?#~*é"}];
        CHECK([[[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding]
            isEqual:@"key+%2B%26%3D=a%2Bb+c%26d%3De%2F%3F%23%7E*%C3%A9"],
            "Form encoding handles reserved characters, spaces, and UTF8");
        CHECK([IPDiscordOAuthRequest formEncodedData:(id)@{@"value": @42}] == nil, "Non-string form values rejected");

        NSURLRequest *token = [request tokenRequestForCode:@"code+with&reserved=chars"];
        CHECK([token.URL.absoluteString isEqual:@"https://discord.com/api/oauth2/token"] &&
              [token.HTTPMethod isEqual:@"POST"] && token.timeoutInterval == 30, "Token exchange uses bounded HTTPS POST");
        CHECK(token.cachePolicy == NSURLRequestReloadIgnoringLocalCacheData && !token.HTTPShouldHandleCookies &&
              [[token valueForHTTPHeaderField:@"Cache-Control"] isEqual:@"no-store"], "Token request avoids browser cookies and caches");
        CHECK([[token valueForHTTPHeaderField:@"Content-Type"] isEqual:@"application/x-www-form-urlencoded"] &&
              [Body(token) containsString:@"code=code%2Bwith%26reserved%3Dchars"] &&
              [Body(token) containsString:[@"code_verifier=" stringByAppendingString:request.verifier]] &&
              [Body(token) containsString:@"grant_type=authorization_code"] &&
              [Body(token) containsString:@"redirect_uri=discord-1561870047562043402%3A%2Fauthorize%2Fcallback"],
              "Token request binds code, private verifier, grant, and redirect in form body");
        CHECK(![Body(token) containsString:@"client_secret"] && token.URL.query == nil, "Public-client exchange has no secret or sensitive URL query");
        CHECK([request tokenRequestForCode:@""] == nil && [request tokenRequestForCode:@"bad\ncode"] == nil,
              "Invalid codes cannot create token requests");
        NSURLRequest *revoke = [IPDiscordOAuthRequest revocationRequestForToken:@"test-refresh+token&value"];
        CHECK([revoke.URL.absoluteString isEqual:@"https://discord.com/api/oauth2/token/revoke"] &&
              [revoke.HTTPMethod isEqual:@"POST"] && revoke.timeoutInterval == 30 &&
              [Body(revoke) containsString:@"token=test-refresh%2Btoken%26value"] &&
              [Body(revoke) containsString:@"token_type_hint=refresh_token"], "Revocation safely encodes token with refresh hint");
        CHECK([IPDiscordOAuthRequest revocationRequestForToken:@""] == nil, "Empty token cannot create revocation request");
        printf("OAuth request validation: %lu checks passed\n", (unsigned long)checks);
    }
    return 0;
}
