#import "IPOAuthStore.h"
#import <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

NSString *const IPOAuthStoreErrorDomain = @"com.kainograze.iPresence.OAuthStore";
static const char *CredentialName = "com.kainograze.iPresence.oauth.plist";
static const char *LockName = "com.kainograze.iPresence.oauth.lock";
static const NSUInteger MaximumCredentialBytes = 65536;
#if defined(IPOAUTH_STORE_TESTING)
static NSString *TestDirectory;
#endif

static void SetError(NSError **error, IPOAuthStoreErrorCode code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:IPOAuthStoreErrorDomain code:code
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL SafeFile(struct stat status) {
    return S_ISREG(status.st_mode) && status.st_uid == geteuid()
        && (status.st_mode & 07777) == 0600 && status.st_nlink == 1;
}

static NSDictionary *ValidatedCredentials(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *credentials = value;
    for (NSString *key in @[@"accessToken", @"refreshToken", @"scope", @"sessionID"]) {
        id field = credentials[key];
        if (![field isKindOfClass:NSString.class] || [field length] == 0 || [field length] > 16384) return nil;
    }
    if (![[NSUUID alloc] initWithUUIDString:credentials[@"sessionID"]]) return nil;
    id expiration = credentials[@"expiresAt"];
    if (![expiration isKindOfClass:NSNumber.class]
        || CFGetTypeID((__bridge CFTypeRef)expiration) == CFBooleanGetTypeID()
        || !isfinite([expiration doubleValue]) || [expiration doubleValue] <= 0) return nil;
    NSSet *scopes = [NSSet setWithArray:[credentials[@"scope"] componentsSeparatedByCharactersInSet:
                                       NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    if (![scopes containsObject:@"openid"] || ![scopes containsObject:@"sdk.social_layer_presence"]) return nil;
    // Expired access tokens remain usable as a record to refresh. Copy only the
    // known schema, never caller-supplied extra fields or mutable containers.
    return @{@"accessToken": [credentials[@"accessToken"] copy],
             @"refreshToken": [credentials[@"refreshToken"] copy],
             @"expiresAt": @([expiration doubleValue]),
             @"scope": [credentials[@"scope"] copy],
             @"sessionID": [credentials[@"sessionID"] copy]};
}

static int OpenDirectory(NSString *path, NSError **error) {
    int directory = open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat status;
    if (directory < 0) {
        SetError(error, IPOAuthStoreErrorIO, @"Cannot open the private credential directory.");
        return -1;
    }
    if (fstat(directory, &status) != 0 || !S_ISDIR(status.st_mode)
        || status.st_uid != geteuid() || (status.st_mode & 0022) != 0) {
        close(directory);
        SetError(error, IPOAuthStoreErrorUnsafeFile, @"The credential directory has unsafe ownership or permissions.");
        return -1;
    }
    return directory;
}

static int LockDirectory(int directory, NSError **error) {
    int lock = openat(directory, LockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
    struct stat status;
    if (lock < 0) {
        SetError(error, IPOAuthStoreErrorIO, @"Cannot open the private credential lock.");
        return -1;
    }
    if (fstat(lock, &status) != 0 || !SafeFile(status)) {
        close(lock);
        SetError(error, IPOAuthStoreErrorUnsafeFile, @"The credential lock has unsafe ownership or permissions.");
        return -1;
    }
    int result;
    do { result = flock(lock, LOCK_EX); } while (result != 0 && errno == EINTR);
    struct stat namedStatus;
    if (result != 0 || fstatat(directory, LockName, &namedStatus, AT_SYMLINK_NOFOLLOW) != 0
        || !SafeFile(namedStatus) || status.st_ino != namedStatus.st_ino || status.st_dev != namedStatus.st_dev) {
        close(lock);
        SetError(error, IPOAuthStoreErrorUnsafeFile, @"Cannot securely lock the credential store.");
        return -1;
    }
    return lock;
}

// Called only while holding the persistent lock. A missing file is permitted.
static BOOL SafeDestination(int directory, NSError **error) {
    struct stat status;
    if (fstatat(directory, CredentialName, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno == ENOENT) return YES;
        SetError(error, IPOAuthStoreErrorIO, @"Cannot inspect the credential file.");
        return NO;
    }
    if (!SafeFile(status)) {
        SetError(error, IPOAuthStoreErrorUnsafeFile, @"The credential file has unsafe ownership or permissions.");
        return NO;
    }
    return YES;
}

static NSDictionary *ReadLocked(int directory) {
    int file = openat(directory, CredentialName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (file < 0) return nil;
    struct stat status;
    if (fstat(file, &status) != 0 || !SafeFile(status) || status.st_size <= 0
        || (uint64_t)status.st_size > MaximumCredentialBytes) {
        close(file);
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)status.st_size];
    NSUInteger position = 0;
    while (position < data.length) {
        ssize_t count = read(file, (char *)data.mutableBytes + position, data.length - position);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(file); return nil; }
        position += (NSUInteger)count;
    }
    close(file);
    id decoded = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                           format:NULL error:NULL];
    return ValidatedCredentials(decoded);
}

static BOOL WriteLocked(int directory, NSData *data, NSError **error) {
    NSString *temporaryName = [NSString stringWithFormat:@".ipresence-oauth-%@.tmp", NSUUID.UUID.UUIDString];
    const char *temporary = temporaryName.fileSystemRepresentation;
    int file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (file < 0) {
        SetError(error, IPOAuthStoreErrorIO, @"Cannot create the private credential file.");
        return NO;
    }
    BOOL success = YES;
    // A restrictive inherited umask must not leave a successful save unreadable.
    if (fchmod(file, 0600) != 0) success = NO;
    NSUInteger position = 0;
    while (success && position < data.length) {
        ssize_t count = write(file, (const char *)data.bytes + position, data.length - position);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { success = NO; break; }
        position += (NSUInteger)count;
    }
    if (success && fsync(file) != 0) success = NO;
    if (close(file) != 0) success = NO;
    if (success) success = SafeDestination(directory, error);
    if (success && renameat(directory, temporary, directory, CredentialName) != 0) success = NO;
    if (success && fsync(directory) != 0) success = NO;
    unlinkat(directory, temporary, 0);
    if (!success && (!error || !*error))
        SetError(error, IPOAuthStoreErrorIO, @"Cannot save the private credential file.");
    return success;
}

@implementation IPOAuthStore
+ (NSString *)directory {
#if defined(IPOAUTH_STORE_TESTING)
    @synchronized (self) { if (TestDirectory) return TestDirectory; }
#endif
    return @"/var/mobile/Library/Preferences";
}

+ (NSDictionary *)credentials {
    int directory = OpenDirectory([self directory], NULL);
    if (directory < 0) return nil;
    int lock = LockDirectory(directory, NULL);
    NSDictionary *credentials = lock < 0 ? nil : ReadLocked(directory);
    if (lock >= 0) close(lock);
    close(directory);
    return credentials;
}

+ (BOOL)saveCredentials:(NSDictionary *)credentials replacingSession:(NSString *)sessionID error:(NSError **)error {
    if (error) *error = nil;
    NSDictionary *validated = ValidatedCredentials(credentials);
    if (!validated) {
        SetError(error, IPOAuthStoreErrorInvalidCredentials, @"The OAuth credentials are incomplete or invalid.");
        return NO;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:validated format:NSPropertyListBinaryFormat_v1_0
                                                           options:0 error:NULL];
    if (!data || data.length > MaximumCredentialBytes) {
        SetError(error, IPOAuthStoreErrorInvalidCredentials, @"The OAuth credentials cannot be stored.");
        return NO;
    }
    int directory = OpenDirectory([self directory], error);
    if (directory < 0) return NO;
    int lock = LockDirectory(directory, error);
    BOOL success = NO;
    if (lock >= 0 && SafeDestination(directory, error)) {
        if (sessionID && ![ReadLocked(directory)[@"sessionID"] isEqualToString:sessionID]) {
            SetError(error, IPOAuthStoreErrorSessionMismatch, @"The Discord login changed before this operation completed.");
        } else {
            success = WriteLocked(directory, data, error);
        }
    }
    if (lock >= 0) close(lock);
    close(directory);
    return success;
}

+ (BOOL)clearSession:(NSString *)sessionID error:(NSError **)error {
    if (error) *error = nil;
    int directory = OpenDirectory([self directory], error);
    if (directory < 0) return NO;
    int lock = LockDirectory(directory, error);
    BOOL success = NO;
    if (lock >= 0 && SafeDestination(directory, error)) {
        if (sessionID && ![ReadLocked(directory)[@"sessionID"] isEqualToString:sessionID]) {
            SetError(error, IPOAuthStoreErrorSessionMismatch, @"The Discord login changed before this operation completed.");
        } else {
            success = unlinkat(directory, CredentialName, 0) == 0 || errno == ENOENT;
            if (success) success = fsync(directory) == 0;
            if (!success) SetError(error, IPOAuthStoreErrorIO, @"Cannot remove the private credential file.");
        }
    }
    if (lock >= 0) close(lock);
    close(directory);
    return success;
}

+ (void)clearCredentials { [self clearCredentialsWithError:NULL]; }
+ (BOOL)clearCredentialsWithError:(NSError **)error { return [self clearSession:nil error:error]; }
+ (BOOL)clearCredentialsIfSessionMatches:(NSString *)sessionID {
    if (![sessionID isKindOfClass:NSString.class] || !sessionID.length) return NO;
    return [self clearSession:sessionID error:NULL];
}
+ (void)notifyChanged {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.kainograze.iPresence.settingsChanged"), NULL, NULL, YES);
}
#if defined(IPOAUTH_STORE_TESTING)
+ (void)setDirectoryForTesting:(NSString *)directory {
    @synchronized (self) { TestDirectory = [directory copy]; }
}
#endif
@end
