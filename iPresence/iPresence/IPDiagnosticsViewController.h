// Original project by kainograze. Updated by 3h6_1.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Owns the private, already-sanitized snapshot until the viewer is dismissed.
@interface IPDiagnosticsViewController : UIViewController
- (nullable instancetype)initWithSnapshotURL:(NSURL *)snapshotURL;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
