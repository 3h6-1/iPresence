// Original project by kainograze. Updated by 3h6_1.
// Isolated UI regression fixture: no authorization, real clipboard or network.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "ViewController.h"
#import "IPDiagnosticsViewController.h"
#import "IPDiagnostics.h"
#import "IPOAuthStore.h"

@interface ViewController (DiagnosticsTest)
- (void)shareDiagnostics;
@end
@interface IPDiagnosticsViewController (DiagnosticsTest)
- (void)copyReport;
- (void)saveToFiles;
- (void)closeReport;
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller;
@end
static NSUInteger Checks, CopyCalls;
static NSDictionary *ClipboardOptions;
static NSArray *ClipboardItems;
static UIDocumentPickerViewController *CapturedPicker;
#define CHECK(condition, message) do { Checks++; if (!(condition)) { NSLog(@"DIAGNOSTICS_VIEWER_TEST failure: %s", message); abort(); } } while (0)
static NSString *Document(NSString *name) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:name];
}
@interface IPTestPasteboard : NSObject
- (void)setItems:(NSArray *)items options:(NSDictionary *)options;
@end
@implementation IPTestPasteboard
- (void)setItems:(NSArray *)items options:(NSDictionary *)options {
    CopyCalls++;
    ClipboardItems = [items copy];
    ClipboardOptions = [options copy];
}
@end
static id FakePasteboard(id self, SEL selector) {
    static IPTestPasteboard *pasteboard;
    if (!pasteboard) pasteboard = [IPTestPasteboard new];
    return pasteboard;
}
static void CapturePresentation(id self, SEL selector, UIViewController *controller, BOOL animated, void (^completion)(void)) {
    CHECK([controller isKindOfClass:UIDocumentPickerViewController.class], "Save presents document picker");
    CHECK(![controller isKindOfClass:UIActivityViewController.class], "Save never presents activity sheet");
    CapturedPicker = (UIDocumentPickerViewController *)controller;
    if (completion) completion();
}
static UIDocumentPickerViewController *UnavailablePicker(id self, SEL selector) NS_RETURNS_RETAINED;
static UIDocumentPickerViewController *UnavailablePicker(id self, SEL selector) { return nil; }
static void SaveResult(void) {
    NSDictionary *result = @{@"passed": @YES, @"checks": @(Checks), @"clipboardWrites": @(CopyCalls),
        @"activitySheetUsed": @NO, @"actualFilesUIExercised": @NO};
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
    [json writeToFile:Document(@"DiagnosticsViewerResult.json") atomically:YES];
    NSLog(@"DIAGNOSTICS_VIEWER_TEST passed %lu checks", (unsigned long)Checks);
}
__attribute__((constructor)) static void InstallDiagnosticsViewerTests(void) {
    NSString *directory = Document(@"DiagnosticsFixture");
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:NULL];
    [IPDiagnostics setDirectoryForTesting:directory];
    [IPOAuthStore setDirectoryForTesting:directory];
    Method pasteboard = class_getClassMethod(UIPasteboard.class, @selector(generalPasteboard));
    method_setImplementation(pasteboard, (IMP)FakePasteboard);
    Method present = class_getInstanceMethod(UIViewController.class, @selector(presentViewController:animated:completion:));
    CHECK(class_addMethod(IPDiagnosticsViewController.class, @selector(presentViewController:animated:completion:), (IMP)CapturePresentation, method_getTypeEncoding(present)), "Test intercepts only viewer presentation");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UINavigationController *root = (UINavigationController *)UIApplication.sharedApplication.delegate.window.rootViewController;
        ViewController *settings = (ViewController *)root.topViewController;
        [IPDiagnostics recordEvent:@"signin_started" fields:@{@"method": @"native", @"token": @"SYNTHETIC-SECRET-NEVER-LOG"}];
        [settings shareDiagnostics];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            UINavigationController *navigation = (UINavigationController *)settings.presentedViewController;
            CHECK([navigation isKindOfClass:UINavigationController.class], "Diagnostics opens an in-app navigation controller");
            IPDiagnosticsViewController *viewer = (IPDiagnosticsViewController *)navigation.topViewController;
            CHECK([viewer isKindOfClass:IPDiagnosticsViewController.class], "Diagnostics presents dedicated viewer");
            CHECK(![settings.presentedViewController isKindOfClass:UIActivityViewController.class], "Entry point never creates activity sheet");
            CHECK(CopyCalls == 0, "Opening viewer never writes clipboard");
            NSString *report = [viewer valueForKey:@"reportText"];
            CHECK([report containsString:@"metadata"] && ![report containsString:@"SYNTHETIC-SECRET-NEVER-LOG"], "Viewer contains sanitized report");
            UITextView *text = [viewer valueForKey:@"reportView"];
            CHECK(!text.editable && !text.selectable && [text.text isEqual:report], "Read-only report cannot open a system selection share menu");
            NSURL *snapshot = [viewer valueForKey:@"snapshotURL"];
            CHECK([NSFileManager.defaultManager fileExistsAtPath:snapshot.path], "Snapshot retained while viewer open");
            NSData *snapshotBeforeRepeat = [NSData dataWithContentsOfURL:snapshot];
            [settings shareDiagnostics];
            CHECK(settings.presentedViewController == navigation, "Repeated diagnostics action keeps the first viewer");
            CHECK([[NSData dataWithContentsOfURL:snapshot] isEqual:snapshotBeforeRepeat], "Repeated diagnostics action does not replace or delete its snapshot");
            NSDictionary *original = [NSJSONSerialization JSONObjectWithData:snapshotBeforeRepeat options:0 error:NULL];
            [viewer copyReport];
            CHECK(CopyCalls == 1 && [ClipboardItems.firstObject[@"public.utf8-plain-text"] isEqual:report], "Copy matches displayed sanitized report exactly");
            NSDictionary *copied = [NSJSONSerialization JSONObjectWithData:[report dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
            CHECK([original isEqual:copied], "Copied JSON equals exported snapshot");
            CHECK([ClipboardOptions[UIPasteboardOptionLocalOnly] boolValue], "Clipboard restricted to local device");
            NSTimeInterval remaining = [ClipboardOptions[UIPasteboardOptionExpirationDate] timeIntervalSinceNow];
            CHECK(remaining > 590 && remaining <= 600, "Clipboard expires after ten minutes");
            UIWindow *window = UIApplication.sharedApplication.delegate.window;
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds];
            UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
            }];
            [UIImagePNGRepresentation(image) writeToFile:Document(@"DiagnosticsViewer.png") atomically:YES];
            Method factory = class_getInstanceMethod(IPDiagnosticsViewController.class, NSSelectorFromString(@"newDocumentPicker"));
            IMP originalFactory = method_setImplementation(factory, (IMP)UnavailablePicker);
            [viewer saveToFiles];
            CHECK(CapturedPicker == nil && [[[viewer valueForKey:@"statusLabel"] text] containsString:@"Copy the report"], "Unavailable Files UI keeps copy fallback");
            method_setImplementation(factory, originalFactory);
            [viewer saveToFiles];
            CHECK(CapturedPicker.delegate == (id<UIDocumentPickerDelegate>)viewer, "Files export returns result to viewer");
            [viewer viewDidDisappear:NO];
            CHECK([NSFileManager.defaultManager fileExistsAtPath:snapshot.path], "Presenting an export picker does not discard its source");
            [viewer documentPickerWasCancelled:CapturedPicker];
            CHECK([NSFileManager.defaultManager fileExistsAtPath:snapshot.path], "Canceling Files preserves report and copy fallback");
            [viewer closeReport];
            CHECK(![NSFileManager.defaultManager fileExistsAtPath:snapshot.path], "Close removes private export snapshot");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                CHECK(settings.presentedViewController == nil, "Close dismisses viewer");
                [settings shareDiagnostics];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    UINavigationController *second = (UINavigationController *)settings.presentedViewController;
                    IPDiagnosticsViewController *secondViewer = (IPDiagnosticsViewController *)second.topViewController;
                    NSURL *secondSnapshot = [secondViewer valueForKey:@"snapshotURL"];
                    CHECK([NSFileManager.defaultManager fileExistsAtPath:secondSnapshot.path], "A new export opens after close");
                    [settings dismissViewControllerAnimated:NO completion:^{
                        CHECK(![NSFileManager.defaultManager fileExistsAtPath:secondSnapshot.path], "External dismissal removes private snapshot");
                        CHECK(CopyCalls == 1, "Dismiss and reopen never write clipboard");
                        SaveResult();
                    }];
                });
            });
        });
    });
}
