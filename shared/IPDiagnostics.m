// Original project by kainograze. Updated by 3h6_1.
#import "IPDiagnostics.h"
#import <CoreFoundation/CoreFoundation.h>
#import <TargetConditionals.h>
#import <os/log.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <unistd.h>

static const NSUInteger MaximumLogBytes = 65536;
static const char *CurrentName = "current.jsonl";
static const char *PreviousName = "previous.jsonl";
static const char *ExportName = "diagnostics-export.json";
#if defined(IPDIAGNOSTICS_TESTING)
static NSString *TestDirectory;
#endif

static NSSet *Events(void) {
    static NSSet *events; static dispatch_once_t once;
    dispatch_once(&once, ^{ events = [NSSet setWithArray:@[
        @"app_launch", @"app_active", @"app_background", @"sign_in_begin", @"sign_in_rejected",
        @"auth_browser_start", @"auth_browser_completion", @"auth_callback", @"auth_callback_rejected",
        @"token_exchange_begin", @"token_exchange_end", @"credentials_save", @"sign_in_finish",
        @"sign_in_cancel", @"sign_in_timeout", @"sign_out_begin", @"sign_out_finish",
        @"web_navigation", @"web_navigation_error", @"network_probe", @"diagnostics_export",
        @"signin_started", @"native_open_result", @"browser_started", @"callback_received", @"callback_rejected",
        @"exchange_started", @"exchange_completed", @"credentials_saved", @"signin_finished", @"signin_cancelled",
        @"signin_timed_out", @"signout_started", @"revocation_completed", @"redirect_blocked", @"foreground", @"background"
    ]]; });
    return events;
}

static NSDictionary *Enums(void) {
    static NSDictionary *enums; static dispatch_once_t once;
    dispatch_once(&once, ^{ enums = @{
        @"phase": @[@"idle", @"authorizing", @"exchanging", @"revoking"],
        @"result": @[@"started", @"success", @"failure", @"cancelled", @"timeout", @"ignored", @"rejected"],
        @"source": @[@"browser", @"app_delegate", @"web_session", @"session", @"http", @"manual", @"watchdog"],
        @"method": @[@"native", @"browser", @"isolated_browser"],
        @"reason": @[@"missing_window", @"request_invalid", @"start_failed", @"network_error", @"http_error",
            @"invalid_response", @"scope_missing", @"save_failed", @"state_mismatch", @"invalid_callback",
            @"access_denied", @"unexpected_error", @"busy", @"deadline", @"user_cancelled", @"none"],
        @"error_domain": @[@"url_loading", @"web_authentication", @"oauth_request", @"credential_store",
            @"cocoa", @"posix", @"cfnetwork", @"other"],
        @"navigation": @[@"started", @"redirected", @"committed", @"finished", @"failed", @"cancelled"],
        @"browser": @[@"authentication_session", @"safari", @"system", @"external"],
        @"endpoint": @[@"authorize", @"token", @"revoke", @"connectivity"]
    }; });
    return enums;
}
static NSSet *BooleanFields(void) {
    static NSSet *fields; static dispatch_once_t once;
    dispatch_once(&once, ^{ fields = [NSSet setWithArray:@[@"started", @"callback_present", @"error_present",
        @"stored_credentials", @"busy", @"accepted", @"cancel_available", @"ephemeral", @"can_open_discord",
        @"network_reachable", @"code_present", @"state_valid", @"token_present", @"refresh_present", @"window_present", @"success"]]; });
    return fields;
}
static NSDictionary *NumberRanges(void) {
    static NSDictionary *ranges; static dispatch_once_t once;
    dispatch_once(&once, ^{ ranges = @{@"http_status": @[@100, @599], @"error_code": @[@(-200000), @200000],
        @"duration_ms": @[@0, @600000], @"bytes": @[@0, @1048576], @"response_bytes": @[@0, @1048576], @"attempt": @[@0, @1000000],
        @"watchdog_seconds": @[@0, @600], @"application_state": @[@0, @2]}; });
    return ranges;
}
static NSDictionary *SanitizedFields(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    // Iterate the schema rather than caller keys: even hostile dictionary keys
    // and nested containers never reach serialization or console formatting.
    for (NSString *key in Enums()) {
        id candidate = value[key];
        if ([candidate isKindOfClass:NSString.class] && [Enums()[key] containsObject:candidate]) fields[key] = [candidate copy];
    }
    for (NSString *key in BooleanFields()) {
        id candidate = value[key];
        if ([candidate isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)candidate) == CFBooleanGetTypeID()) fields[key] = @([candidate boolValue]);
    }
    for (NSString *key in NumberRanges()) {
        id candidate = value[key];
        if (![candidate isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)candidate) == CFBooleanGetTypeID()) continue;
        double number = [candidate doubleValue]; NSArray *range = NumberRanges()[key];
        if (isfinite(number) && floor(number) == number && number >= [range[0] doubleValue] && number <= [range[1] doubleValue]) fields[key] = @((long long)number);
    }
    return fields;
}
static NSDictionary *Record(id event, id fields, id timestamp) {
    if (![event isKindOfClass:NSString.class] || ![Events() containsObject:event]) return nil;
    if (![timestamp isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)timestamp) == CFBooleanGetTypeID()) return nil;
    double time = [timestamp doubleValue];
    if (!isfinite(time) || time <= 0 || time >= 4102444800.0) return nil;
    return @{@"event": [event copy], @"timestamp": @((long long)time), @"fields": SanitizedFields(fields)};
}
static BOOL SafeFile(struct stat status) {
    return S_ISREG(status.st_mode) && status.st_uid == geteuid() && (status.st_mode & 07777) == 0600 && status.st_nlink == 1;
}
static BOOL SafeDirectory(int directory, BOOL exact) {
    struct stat status;
    return directory >= 0 && fstat(directory, &status) == 0 && S_ISDIR(status.st_mode)
        && status.st_uid == geteuid() && (exact ? (status.st_mode & 07777) == 0700 : (status.st_mode & 0022) == 0);
}
static NSString *DirectoryPath(void) {
#if defined(IPDIAGNOSTICS_TESTING)
    if (TestDirectory) return TestDirectory;
#endif
    return @"/var/mobile/Library/Preferences/iPresenceDiagnostics";
}
static int OpenDirectory(void) {
#if defined(IPDIAGNOSTICS_TESTING)
    if (TestDirectory) {
        int directory = open(TestDirectory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (SafeDirectory(directory, YES)) return directory;
        if (directory >= 0) close(directory);
        return -1;
    }
#endif
    int parent = open("/var/mobile/Library/Preferences", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (!SafeDirectory(parent, NO)) { if (parent >= 0) close(parent); return -1; }
    if (mkdirat(parent, "iPresenceDiagnostics", 0700) != 0 && errno != EEXIST) { close(parent); return -1; }
    int directory = openat(parent, "iPresenceDiagnostics", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    close(parent);
    if (!SafeDirectory(directory, YES)) { if (directory >= 0) close(directory); return -1; }
    return directory;
}
static int Lock(int directory) {
    int file = openat(directory, "diagnostics.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
    struct stat status;
    if (file < 0) return -1;
    if (fstat(file, &status) != 0 || !SafeFile(status) || flock(file, LOCK_EX | LOCK_NB) != 0) { close(file); return -1; }
    return file;
}
static BOOL SafeDestination(int directory, const char *name) {
    struct stat status;
    if (fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) != 0) return errno == ENOENT;
    return SafeFile(status);
}
static BOOL WriteBytes(int file, NSData *data) {
    NSUInteger position = 0;
    while (position < data.length) {
        ssize_t count = write(file, (const char *)data.bytes + position, data.length - position);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        position += (NSUInteger)count;
    }
    return YES;
}
static void Append(int directory, NSData *data) {
    if (!SafeDestination(directory, CurrentName)) return;
    int file = openat(directory, CurrentName, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
    struct stat status;
    if (file < 0) return;
    if (fstat(file, &status) != 0 || !SafeFile(status)) { close(file); return; }
    if (status.st_size < 0) { close(file); return; }
    // Do not rotate an unexpectedly oversized file into the retained slot.
    if ((uint64_t)status.st_size > MaximumLogBytes) {
        if (ftruncate(file, 0) != 0) { close(file); return; }
        status.st_size = 0;
    }
    if ((uint64_t)status.st_size + data.length > MaximumLogBytes) {
        close(file);
        if (!SafeDestination(directory, PreviousName) || renameat(directory, CurrentName, directory, PreviousName) != 0) return;
        file = openat(directory, CurrentName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (file < 0) return;
    }
    WriteBytes(file, data);
    close(file);
}
static NSArray *ReadRecords(int directory, const char *name) {
    int file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (file < 0) return @[];
    struct stat status;
    if (fstat(file, &status) != 0 || !SafeFile(status) || status.st_size < 0 || (uint64_t)status.st_size > MaximumLogBytes) { close(file); return @[]; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)status.st_size];
    NSUInteger position = 0;
    while (position < data.length) {
        ssize_t count = read(file, (char *)data.mutableBytes + position, data.length - position);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(file); return @[]; }
        position += (NSUInteger)count;
    }
    close(file);
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSMutableArray *records = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length == 0 || line.length > 2048) continue;
        id parsed = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if (![parsed isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *record = Record(parsed[@"event"], parsed[@"fields"], parsed[@"timestamp"]);
        if (record) [records addObject:record];
    }
    return records;
}
static NSString *Version(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] == 0 || [value length] > 32) return @"unknown";
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789.+-"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound ? value : @"unknown";
}
static NSDictionary *Metadata(void) {
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    NSString *hardware = @"unknown"; struct utsname system;
    if (uname(&system) == 0) {
        NSString *machine = [NSString stringWithUTF8String:system.machine];
        NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^(iPhone[0-9]+,[0-9]+|iPad[0-9]+,[0-9]+|iPod[0-9]+,[0-9]+|arm64|x86_64)$" options:0 error:NULL];
        if ([pattern numberOfMatchesInString:machine options:0 range:NSMakeRange(0, machine.length)] == 1) hardware = machine;
    }
    return @{@"app_version": Version([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]),
        @"app_build": Version([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]),
        @"os_version": [NSString stringWithFormat:@"%ld.%ld.%ld", (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion],
        @"platform": TARGET_OS_IPHONE ? @"iOS" : @"macOS", @"hardware": hardware};
}
static void ExportError(NSError **error) {
    if (error) *error = [NSError errorWithDomain:@"com.kainograze.iPresence.Diagnostics" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"Could not prepare private diagnostics. Reopen the rootless installation and try again."}];
}

@implementation IPDiagnostics
+ (void)recordEvent:(NSString *)event fields:(NSDictionary *)fields {
    NSDictionary *record = Record(event, fields, @(NSDate.date.timeIntervalSince1970));
    if (!record) return;
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
    if (!json || json.length > 2047) return;
#if !defined(IPDIAGNOSTICS_TESTING)
    NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.kainograze.iPresence", "diagnostics"); });
    os_log_with_type(log, OS_LOG_TYPE_DEFAULT, "iPresence diagnostics %{public}s", line.UTF8String);
#endif
    NSMutableData *data = [json mutableCopy]; [data appendBytes:"\n" length:1];
    @synchronized (self) {
        int directory = OpenDirectory(); if (directory < 0) return;
        int lock = Lock(directory);
        if (lock >= 0) { Append(directory, data); close(lock); }
        close(directory);
    }
}
+ (NSDictionary *)fieldsForError:(NSError *)error {
    if (![error isKindOfClass:NSError.class]) return @{};
    NSDictionary *domains = @{NSURLErrorDomain: @"url_loading", @"com.apple.AuthenticationServices.WebAuthenticationSession": @"web_authentication",
        @"com.kainograze.iPresence.OAuthRequest": @"oauth_request", @"com.kainograze.iPresence.OAuthStore": @"credential_store",
        NSCocoaErrorDomain: @"cocoa", NSPOSIXErrorDomain: @"posix", @"kCFErrorDomainCFNetwork": @"cfnetwork"};
    return SanitizedFields(@{@"error_domain": domains[error.domain] ?: @"other", @"error_code": @(error.code)});
}
+ (NSURL *)exportSnapshotWithError:(NSError **)error {
    if (error) *error = nil;
    [self recordEvent:@"diagnostics_export" fields:nil];
    @synchronized (self) {
        int directory = OpenDirectory();
        if (directory < 0) { ExportError(error); return nil; }
        int lock = Lock(directory);
        if (lock < 0) { close(directory); ExportError(error); return nil; }
        NSMutableArray *records = [ReadRecords(directory, PreviousName) mutableCopy];
        [records addObjectsFromArray:ReadRecords(directory, CurrentName)];
        NSDictionary *snapshot = @{@"format_version": @1, @"metadata": Metadata(), @"events": records,
            @"privacy": @"Contains only allowlisted technical events and app/device versions. No authorization URLs, codes, state, verifiers, tokens, usernames, or HTTP bodies."};
        NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingSortedKeys error:NULL];
        const char *temporary = "diagnostics-export.tmp";
        BOOL success = data && data.length <= MaximumLogBytes * 2 + 4096 && SafeDestination(directory, ExportName) && SafeDestination(directory, temporary);
        if (success) unlinkat(directory, temporary, 0);
        int file = success ? openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600) : -1;
        success = file >= 0;
        if (success) success = fchmod(file, 0600) == 0 && WriteBytes(file, data) && fsync(file) == 0;
        if (file >= 0 && close(file) != 0) success = NO;
        if (success) success = renameat(directory, temporary, directory, ExportName) == 0;
        if (!success && SafeDestination(directory, temporary)) unlinkat(directory, temporary, 0);
        close(lock); close(directory);
        if (!success) { ExportError(error); return nil; }
        return [NSURL fileURLWithPath:[DirectoryPath() stringByAppendingPathComponent:@"diagnostics-export.json"]];
    }
}
+ (void)removeExportSnapshot:(NSURL *)url {
    @synchronized (self) {
        NSURL *expected = [NSURL fileURLWithPath:[DirectoryPath() stringByAppendingPathComponent:@"diagnostics-export.json"]];
        if (![url isEqual:expected]) return;
        int directory = OpenDirectory(); if (directory < 0) return;
        int lock = Lock(directory);
        if (lock >= 0) { if (SafeDestination(directory, ExportName)) unlinkat(directory, ExportName, 0); close(lock); }
        close(directory);
    }
}
#if defined(IPDIAGNOSTICS_TESTING)
+ (void)setDirectoryForTesting:(NSString *)directory { @synchronized (self) { TestDirectory = [directory copy]; } }
#endif
@end
