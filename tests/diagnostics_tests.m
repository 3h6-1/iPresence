// Original project by kainograze. Updated by 3h6_1.
#import <Foundation/Foundation.h>
#import "IPDiagnostics.h"
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>

static NSUInteger checks;
#define CHECK(condition, message) do { checks++; if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); exit(1); } } while (0)
static NSString *directory;
static NSString *Path(NSString *name) { return [directory stringByAppendingPathComponent:name]; }
static void Reset(void) {
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL]) {
        [NSFileManager.defaultManager removeItemAtPath:Path(name) error:NULL];
    }
}
static NSDictionary *Snapshot(void) {
    NSError *error = nil;
    NSURL *url = [IPDiagnostics exportSnapshotWithError:&error];
    CHECK(url && !error, "Private snapshot is created");
    NSData *data = [NSData dataWithContentsOfURL:url];
    NSDictionary *value = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    CHECK([value isKindOfClass:NSDictionary.class], "Export is valid JSON");
    return value;
}
static NSDictionary *Event(NSDictionary *snapshot, NSString *name) {
    for (NSDictionary *event in snapshot[@"events"]) if ([event[@"event"] isEqual:name]) return event;
    return nil;
}
static NSString *Text(NSString *name) { return [NSString stringWithContentsOfFile:Path(name) encoding:NSUTF8StringEncoding error:NULL] ?: @""; }
static void WritePrivate(NSString *name, NSString *text) {
    CHECK([text writeToFile:Path(name) atomically:NO encoding:NSUTF8StringEncoding error:NULL], "Write test record");
    CHECK(chmod(Path(name).fileSystemRepresentation, 0600) == 0, "Test record private");
}
int main(void) {
    @autoreleasepool {
        directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"ipresence-diagnostics-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        CHECK([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions: @0700} error:NULL], "Create isolated private directory");
        [IPDiagnostics setDirectoryForTesting:directory];
        NSString *secret = @"SYNTHETIC-SECRET-NEVER-LOG";
        [IPDiagnostics recordEvent:@"signin_started" fields:@{@"method": @"native", @"success": @YES,
            @"url": secret, @"code": secret, @"state": secret, @"verifier": secret, @"token": secret,
            @"username": secret, @"body": secret, @"message": secret, @"nested": @{@"secret": secret}}];
        [IPDiagnostics recordEvent:secret fields:@{@"success": @YES}];
        NSDictionary *snapshot = Snapshot();
        NSDictionary *fields = Event(snapshot, @"signin_started")[@"fields"];
        CHECK(fields.count == 2 && [fields[@"method"] isEqual:@"native"] && [fields[@"success"] boolValue], "Only exact allowlisted fields remain");
        CHECK(![Text(@"current.jsonl") containsString:secret] && ![Text(@"diagnostics-export.json") containsString:secret], "Secrets excluded from stored and exported text");
        CHECK(Event(snapshot, secret) == nil, "Unknown event name dropped");
        CHECK(snapshot[@"metadata"][@"os_version"] && snapshot[@"metadata"][@"app_version"] && snapshot[@"metadata"][@"hardware"], "App/OS/hardware versions included");
        for (NSString *name in @[@"current.jsonl", @"diagnostics.lock", @"diagnostics-export.json"]) {
            struct stat status;
            CHECK(lstat(Path(name).fileSystemRepresentation, &status) == 0 && (status.st_mode & 07777) == 0600 && status.st_nlink == 1, "Diagnostic files are private regular files");
        }
        [IPDiagnostics recordEvent:@"exchange_completed" fields:@{@"http_status": @200, @"response_bytes": @12, @"error_code": @(-1009),
            @"method": secret, @"success": @1, @"phase": secret, @"duration_ms": @(NAN), @"bytes": @(-1), @"attempt": @1000001}];
        fields = Event(Snapshot(), @"exchange_completed")[@"fields"];
        CHECK(fields.count == 3 && [fields[@"http_status"] isEqual:@200] && [fields[@"error_code"] isEqual:@(-1009)], "Wrong enums/types/nonfinite/out-of-range values rejected");
        NSError *underlying = [NSError errorWithDomain:secret code:7 userInfo:@{NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLErrorKey: [NSURL URLWithString:@"https://example.invalid/?token=secret"]}];
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:@{NSLocalizedDescriptionKey: secret, NSUnderlyingErrorKey: underlying}];
        NSDictionary *safeError = [IPDiagnostics fieldsForError:error];
        CHECK(safeError.count == 2 && [safeError[@"error_domain"] isEqual:@"url_loading"] && [safeError[@"error_code"] isEqual:@(NSURLErrorNotConnectedToInternet)], "Known error emits only domain label and code");
        CHECK([[IPDiagnostics fieldsForError:underlying][@"error_domain"] isEqual:@"other"], "Unknown error domains are not echoed");
        CHECK([IPDiagnostics fieldsForError:nil].count == 0, "Absent error emits no fields");
        CHECK([IPDiagnostics fieldsForError:[NSError errorWithDomain:secret code:NSIntegerMax userInfo:nil]][@"error_code"] == nil, "Extreme error codes dropped");
        [IPDiagnostics recordEvent:@"exchange_completed" fields:safeError];
        CHECK(![Text(@"current.jsonl") containsString:secret], "Nested error details excluded");

        Reset();
        WritePrivate(@"current.jsonl", [NSString stringWithFormat:@"{\"event\":\"signin_started\",\"timestamp\":1,\"fields\":{\"method\":\"native\",\"url\":\"%@\"},\"token\":\"%@\"}\n{\"event\":\"%@\",\"timestamp\":1}\nnot-json\n", secret, secret, secret]);
        snapshot = Snapshot();
        CHECK([Event(snapshot, @"signin_started")[@"fields"] count] == 1, "Export revalidates tampered record schema");
        CHECK(![Text(@"diagnostics-export.json") containsString:secret], "Export never copies raw log bytes");

        Reset();
        for (NSUInteger index = 0; index < 1600; index++) {
            [IPDiagnostics recordEvent:@"exchange_completed" fields:@{@"http_status": @200, @"response_bytes": @1024, @"attempt": @(index)}];
        }
        for (NSString *name in @[@"current.jsonl", @"previous.jsonl"]) {
            struct stat status;
            CHECK(lstat(Path(name).fileSystemRepresentation, &status) == 0 && status.st_size > 0 && status.st_size <= 65536, "Rotation retains two bounded log files");
        }
        Snapshot();
        CHECK([[NSFileManager.defaultManager attributesOfItemAtPath:Path(@"diagnostics-export.json") error:NULL] fileSize] <= 135168, "Export size bounded");
        NSURL *export = [NSURL fileURLWithPath:Path(@"diagnostics-export.json")];
        [IPDiagnostics removeExportSnapshot:[NSURL fileURLWithPath:Path(@"current.jsonl")]];
        CHECK([NSFileManager.defaultManager fileExistsAtPath:Path(@"current.jsonl")], "Cleanup refuses other paths");
        [IPDiagnostics removeExportSnapshot:export];
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:export.path], "Completed share snapshot removed");

        Reset();
        WritePrivate(@"target", secret);
        CHECK(symlink("target", Path(@"current.jsonl").fileSystemRepresentation) == 0, "Create symlink fixture");
        [IPDiagnostics recordEvent:@"app_launch" fields:nil];
        CHECK([Text(@"target") isEqual:secret], "Logging never follows symlink");
        Snapshot();
        CHECK(![Text(@"diagnostics-export.json") containsString:secret], "Export never reads symlink target");
        Reset();
        WritePrivate(@"target", secret);
        CHECK(link(Path(@"target").fileSystemRepresentation, Path(@"current.jsonl").fileSystemRepresentation) == 0, "Create hardlink fixture");
        [IPDiagnostics recordEvent:@"app_launch" fields:nil];
        CHECK([Text(@"target") isEqual:secret], "Logging rejects multiply linked files");
        Snapshot();
        CHECK(![Text(@"diagnostics-export.json") containsString:secret], "Export rejects multiply linked files");
        Reset();
        WritePrivate(@"current.jsonl", secret);
        CHECK(chmod(Path(@"current.jsonl").fileSystemRepresentation, 0644) == 0, "Create unsafe permissions fixture");
        [IPDiagnostics recordEvent:@"app_launch" fields:nil];
        CHECK([Text(@"current.jsonl") isEqual:secret], "Unsafe log permissions not silently changed");
        Snapshot();
        CHECK(![Text(@"diagnostics-export.json") containsString:secret], "Unsafe log omitted from export");
        Reset();
        WritePrivate(@"target", secret);
        CHECK(symlink("target", Path(@"diagnostics-export.json").fileSystemRepresentation) == 0, "Create export symlink fixture");
        error = nil;
        CHECK(![IPDiagnostics exportSnapshotWithError:&error] && error != nil, "Unsafe export destination rejected with error");
        CHECK([Text(@"target") isEqual:secret], "Export never replaces symlink target");
        Reset();
        WritePrivate(@"target", secret);
        CHECK(symlink("target", Path(@"diagnostics.lock").fileSystemRepresentation) == 0, "Create lock symlink fixture");
        [IPDiagnostics recordEvent:@"app_launch" fields:nil];
        CHECK([Text(@"target") isEqual:secret] && ![NSFileManager.defaultManager fileExistsAtPath:Path(@"current.jsonl")], "Unsafe lock prevents writing any logs");
        CHECK(![IPDiagnostics exportSnapshotWithError:NULL], "Unsafe lock prevents export");
        Reset();
        WritePrivate(@"target", secret);
        CHECK(symlink("target", Path(@"diagnostics-export.tmp").fileSystemRepresentation) == 0, "Create temporary export symlink fixture");
        CHECK(![IPDiagnostics exportSnapshotWithError:NULL] && [Text(@"target") isEqual:secret], "Export cannot follow unsafe temporary destination");
        Reset();
        CHECK(chmod(directory.fileSystemRepresentation, 0755) == 0, "Create nonprivate directory fixture");
        [IPDiagnostics recordEvent:@"app_launch" fields:nil];
        CHECK(![NSFileManager.defaultManager fileExistsAtPath:Path(@"current.jsonl")], "Logging refuses nonprivate directory");
        CHECK(![IPDiagnostics exportSnapshotWithError:NULL], "Export refuses nonprivate directory");
        chmod(directory.fileSystemRepresentation, 0700);
        [NSFileManager.defaultManager removeItemAtPath:directory error:NULL];
        printf("Diagnostics privacy/storage tests passed (%lu checks).\n", (unsigned long)checks);
    }
    return 0;
}
