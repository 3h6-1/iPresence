#import <Foundation/Foundation.h>
#import "IPOAuthStore.h"
#include <fcntl.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>

static NSUInteger checks;
#define CHECK(condition, message) do { checks++; if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); exit(1); } } while (0)

static NSDictionary *Credentials(NSString *session, NSString *access) {
    return @{@"accessToken": access, @"refreshToken": @"test-refresh-not-a-real-secret",
             @"expiresAt": @1, @"scope": @"openid sdk.social_layer_presence",
             @"sessionID": session};
}

static BOOL Save(NSDictionary *credentials, NSString *session) {
    return [IPOAuthStore saveCredentials:credentials replacingSession:session error:NULL];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 4 && strcmp(argv[1], "--writer") == 0) {
            [IPOAuthStore setDirectoryForTesting:[NSString stringWithUTF8String:argv[2]]];
            NSString *session = [NSString stringWithUTF8String:argv[3]];
            for (NSUInteger index = 0; index < 30; index++) {
                if (!Save(Credentials(session, [NSString stringWithFormat:@"writer-%lu", (unsigned long)index]), nil)) return 2;
            }
            return 0;
        }
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"ipresence-oauth-store-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO
            attributes:@{NSFilePosixPermissions: @0700} error:NULL], "Create isolated credential directory");
        [IPOAuthStore setDirectoryForTesting:directory];
        NSString *file = [directory stringByAppendingPathComponent:@"com.kainograze.iPresence.oauth.plist"];
        NSString *lock = [directory stringByAppendingPathComponent:@"com.kainograze.iPresence.oauth.lock"];
        NSString *sessionA = NSUUID.UUID.UUIDString;
        NSString *sessionB = NSUUID.UUID.UUIDString;
        NSDictionary *original = Credentials(sessionA, @"initial-access");
        CHECK([IPOAuthStore credentials] == nil, "Missing credentials return nil");
        CHECK(Save(original, nil), "Save new login");
        CHECK([[IPOAuthStore credentials] isEqual:original], "Expired access with refresh is retained");
        struct stat status;
        CHECK(lstat(file.fileSystemRepresentation, &status) == 0 && (status.st_mode & 0777) == 0600, "Credentials stay private");
        CHECK(lstat(lock.fileSystemRepresentation, &status) == 0 && (status.st_mode & 0777) == 0600, "Lock stays private");
        CHECK(Save(Credentials(sessionA, @"refreshed-access"), sessionA), "Matching refresh succeeds");
        CHECK(Save(Credentials(sessionB, @"new-login-access"), nil), "New login replaces old credentials");
        NSError *error;
        CHECK(![IPOAuthStore saveCredentials:original replacingSession:sessionA error:&error]
            && error.code == IPOAuthStoreErrorSessionMismatch, "Stale refresh cannot overwrite new login");
        CHECK(![IPOAuthStore clearCredentialsIfSessionMatches:sessionA], "Stale auth failure cannot clear a new login");
        CHECK([[IPOAuthStore credentials][@"sessionID"] isEqual:sessionB], "New login survives stale operations");
        CHECK([IPOAuthStore clearCredentialsIfSessionMatches:sessionB], "Matching conditional logout succeeds");
        CHECK(!Save(original, sessionB), "Refresh cannot resurrect a logged-out session");
        CHECK([IPOAuthStore credentials] == nil, "Logout removes credentials");
        CHECK([IPOAuthStore clearCredentialsWithError:&error] && error == nil, "Already absent credentials report successful logout");

        NSArray *invalidFields = @[
            @{@"accessToken": @""}, @{@"refreshToken": @""}, @{@"accessToken": @7},
            @{@"sessionID": @"not-a-uuid"}, @{@"expiresAt": @0}, @{@"expiresAt": @(-1)},
            @{@"expiresAt": @(NAN)}, @{@"expiresAt": @(INFINITY)}, @{@"expiresAt": @YES},
            @{@"expiresAt": @"123"}, @{@"scope": @"openid"},
            @{@"scope": @"openid sdk.social_layer_presence_fake"}];
        for (NSDictionary *field in invalidFields) {
            NSMutableDictionary *invalid = [original mutableCopy];
            [invalid addEntriesFromDictionary:field];
            CHECK(!Save(invalid, nil), "Invalid credential schema rejected");
        }
        NSMutableDictionary *extra = [original mutableCopy];
        extra[@"unexpected"] = @"must-not-persist";
        CHECK(Save(extra, nil) && [IPOAuthStore credentials][@"unexpected"] == nil, "Only agreed credential schema persists");

        CHECK(chmod(file.fileSystemRepresentation, 0644) == 0, "Set unsafe credential permissions");
        CHECK([IPOAuthStore credentials] == nil && !Save(original, nil), "Public credential file rejected");
        CHECK(![IPOAuthStore clearCredentialsWithError:&error] && error.code == IPOAuthStoreErrorUnsafeFile,
            "Logout reports unsafe credentials instead of treating failed read as deletion");
        CHECK(chmod(file.fileSystemRepresentation, 0600) == 0, "Restore credential permissions");
        NSString *link = [directory stringByAppendingPathComponent:@"credential-hard-link"];
        CHECK(linkat(AT_FDCWD, file.fileSystemRepresentation, AT_FDCWD, link.fileSystemRepresentation, 0) == 0, "Create hard-link test");
        CHECK([IPOAuthStore credentials] == nil && !Save(original, nil), "Multiply linked credential file rejected");
        CHECK(unlink(link.fileSystemRepresentation) == 0, "Remove hard-link test");
        [IPOAuthStore clearCredentials];

        NSString *outside = [directory stringByAppendingPathComponent:@"unrelated-file"];
        NSData *sentinel = [@"unrelated contents" dataUsingEncoding:NSUTF8StringEncoding];
        CHECK([sentinel writeToFile:outside atomically:YES], "Create unrelated sentinel");
        CHECK(symlink(outside.fileSystemRepresentation, file.fileSystemRepresentation) == 0, "Create credential symlink");
        CHECK([IPOAuthStore credentials] == nil && !Save(original, nil), "Credential symlink rejected");
        CHECK(![IPOAuthStore clearCredentialsWithError:&error] && error.code == IPOAuthStoreErrorUnsafeFile,
            "Logout reports rejected credential symlink");
        CHECK([[NSData dataWithContentsOfFile:outside] isEqual:sentinel], "Rejected symlink leaves target intact");
        CHECK(unlink(file.fileSystemRepresentation) == 0, "Remove credential symlink");
        CHECK(chmod(lock.fileSystemRepresentation, 0644) == 0, "Set unsafe lock permissions");
        CHECK(!Save(original, nil), "Unsafe lock rejected");
        CHECK(![IPOAuthStore clearCredentialsWithError:&error] && error.code == IPOAuthStoreErrorUnsafeFile,
            "Logout reports unsafe lock");
        CHECK(unlink(lock.fileSystemRepresentation) == 0, "Remove unsafe lock");
        CHECK(symlink(outside.fileSystemRepresentation, lock.fileSystemRepresentation) == 0, "Create lock symlink");
        CHECK(!Save(original, nil), "Lock symlink rejected");
        CHECK(unlink(lock.fileSystemRepresentation) == 0, "Remove lock symlink");
        CHECK(Save(original, nil), "Store recovers with safe lock");
        CHECK([sentinel writeToFile:file atomically:NO], "Write malformed credential data");
        CHECK(chmod(file.fileSystemRepresentation, 0600) == 0 && [IPOAuthStore credentials] == nil, "Malformed file rejected");
        CHECK([IPOAuthStore clearCredentialsWithError:&error] && error == nil,
            "Logout removes malformed but private credential records");
        CHECK(Save(original, nil), "New login replaces malformed private record");
        CHECK(chmod(directory.fileSystemRepresentation, 0777) == 0, "Set unsafe parent directory");
        CHECK([IPOAuthStore credentials] == nil && !Save(original, nil), "Shared-writable parent directory rejected");
        CHECK(![IPOAuthStore clearCredentialsWithError:&error] && error.code == IPOAuthStoreErrorUnsafeFile,
            "Logout reports unsafe parent directory");
        CHECK(chmod(directory.fileSystemRepresentation, 0700) == 0, "Restore parent directory");
        if (geteuid() != 0) {
            CHECK(chmod(directory.fileSystemRepresentation, 0500) == 0, "Set unwritable parent directory");
            CHECK(![IPOAuthStore clearCredentialsWithError:&error] && error.code == IPOAuthStoreErrorIO,
                "Logout reports failed unlink");
            CHECK(chmod(directory.fileSystemRepresentation, 0700) == 0, "Restore writable parent directory");
            CHECK([IPOAuthStore credentials] != nil, "Failed logout retains the existing record");
        }

        // Separate processes exercise the real flock, not only in-process locking.
        NSMutableArray<NSTask *> *writers = [NSMutableArray new];
        for (NSUInteger index = 0; index < 3; index++) {
            NSTask *writer = [NSTask new];
            writer.executableURL = [NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments[0]];
            writer.arguments = @[@"--writer", directory, NSUUID.UUID.UUIDString];
            CHECK([writer launchAndReturnError:NULL], "Start concurrent store writer");
            [writers addObject:writer];
        }
        for (NSUInteger index = 0; index < 50; index++)
            CHECK([IPOAuthStore credentials] != nil, "Concurrent readers see complete credential records");
        for (NSTask *writer in writers) {
            [writer waitUntilExit];
            CHECK(writer.terminationStatus == 0, "Concurrent writer completes without corruption");
        }
        NSArray *leftovers = [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL];
        CHECK([leftovers filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF ENDSWITH '.tmp'"]].count == 0,
            "Atomic writes clean temporary files");
        CHECK([IPOAuthStore clearCredentialsWithError:&error] && error == nil && [IPOAuthStore credentials] == nil,
            "Final logout succeeds and reports deletion");
        CHECK([NSFileManager.defaultManager removeItemAtPath:directory error:NULL], "Clean isolated test directory");
        CHECK(![IPOAuthStore clearCredentialsWithError:&error] && error.code == IPOAuthStoreErrorIO,
            "Logout reports a missing credential directory");
        printf("OAuth credential store: %lu checks passed\n", (unsigned long)checks);
    }
    return 0;
}
