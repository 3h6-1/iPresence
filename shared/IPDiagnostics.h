// Original project by kainograze. Updated by 3h6_1.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Diagnostic records accept only the event/field allowlists in IPDiagnostics.m.
// Never pass URLs, authorization codes/state, PKCE verifiers, tokens, usernames,
// HTTP bodies, or error descriptions. Unknown fields and values are discarded.
@interface IPDiagnostics : NSObject
+ (void)recordEvent:(NSString *)event fields:(nullable NSDictionary<NSString *, id> *)fields;
// Returns only an allowlisted error-domain label and a bounded integer code.
+ (NSDictionary<NSString *, id> *)fieldsForError:(nullable NSError *)error;
// Revalidates saved records and adds app/OS/hardware versions. The private JSON
// snapshot can be reviewed or exported explicitly; no upload is automatic.
+ (nullable NSURL *)exportSnapshotWithError:(NSError * _Nullable * _Nullable)error;
+ (void)removeExportSnapshot:(NSURL *)url;
#if defined(IPDIAGNOSTICS_TESTING)
+ (void)setDirectoryForTesting:(NSString *)directory;
#endif
@end

NS_ASSUME_NONNULL_END
