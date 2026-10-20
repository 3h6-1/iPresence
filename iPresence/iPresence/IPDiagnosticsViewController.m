// Original project by kainograze. Updated by 3h6_1.
#import "IPDiagnosticsViewController.h"
#import "../../shared/IPDiagnostics.h"

@interface IPDiagnosticsViewController () <UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate>
@property(nonatomic, copy) NSURL *snapshotURL;
@property(nonatomic, copy) NSString *reportText;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UITextView *reportView;
@end

@implementation IPDiagnosticsViewController
- (instancetype)initWithSnapshotURL:(NSURL *)snapshotURL {
    if (!snapshotURL.isFileURL) return nil;
    NSData *data = [NSData dataWithContentsOfURL:snapshotURL options:0 error:NULL];
    if (!data || data.length > 135168) return nil;
    id report = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![report isKindOfClass:NSDictionary.class]) return nil;
    NSData *readable = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    NSString *text = [[NSString alloc] initWithData:readable encoding:NSUTF8StringEncoding];
    if (!text) return nil;
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _snapshotURL = [snapshotURL copy];
        _reportText = text;
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Diagnostics";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Close" style:UIBarButtonItemStylePlain target:self action:@selector(closeReport)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Save to Files" style:UIBarButtonItemStylePlain target:self action:@selector(saveToFiles)];
    UIButton *copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    copyButton.configuration = [UIButtonConfiguration filledButtonConfiguration];
    [copyButton setTitle:@"Copy report" forState:UIControlStateNormal];
    [copyButton addTarget:self action:@selector(copyReport) forControlEvents:UIControlEventTouchUpInside];
    self.statusLabel = [UILabel new];
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.statusLabel.adjustsFontForContentSizeCategory = YES;
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.text = @"Review the report below. Copy it or save a file to attach manually. Nothing is sent automatically.";
    self.reportView = [UITextView new];
    self.reportView.editable = NO;
    // Selection's system edit menu can offer Share and re-enter the crashing
    // activity-sheet path. The explicit Copy report button is the copy route.
    self.reportView.selectable = NO;
    self.reportView.alwaysBounceVertical = YES;
    self.reportView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.reportView.adjustsFontForContentSizeCategory = YES;
    self.reportView.text = self.reportText;
    self.reportView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.reportView.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[copyButton, self.statusLabel]];
    controls.axis = UILayoutConstraintAxisVertical;
    controls.spacing = 12;
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    self.reportView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:controls];
    [self.view addSubview:self.reportView];
    [NSLayoutConstraint activateConstraints:@[
        [controls.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [controls.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [controls.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.reportView.topAnchor constraintEqualToAnchor:controls.bottomAnchor constant:16],
        [self.reportView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.reportView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.reportView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12]
    ]];
}
- (void)copyReport {
    // Explicitly local: Universal Clipboard never receives this report, and the
    // OS removes this pasteboard item after ten minutes.
    [UIPasteboard.generalPasteboard setItems:@[@{@"public.utf8-plain-text": self.reportText}]
        options:@{UIPasteboardOptionLocalOnly: @YES,
                  UIPasteboardOptionExpirationDate: [NSDate dateWithTimeIntervalSinceNow:600]}];
    self.statusLabel.text = @"Copied for 10 minutes on this device. Paste the report where you want to send it.";
}
- (UIDocumentPickerViewController *)newDocumentPicker {
    return [[UIDocumentPickerViewController alloc] initForExportingURLs:@[self.snapshotURL] asCopy:YES];
}
- (void)saveToFiles {
    if (!self.snapshotURL || self.presentedViewController) return;
    if (![self.snapshotURL checkResourceIsReachableAndReturnError:NULL]) {
        self.statusLabel.text = @"The temporary file is unavailable. Copy the report instead.";
        return;
    }
    // A document export avoids UIActivityViewController and its activity/icon
    // discovery, including the AirDrop image path seen in the device crash.
    UIDocumentPickerViewController *picker = [self newDocumentPicker];
    if (!picker) {
        self.statusLabel.text = @"Files could not open. Copy the report instead.";
        return;
    }
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    self.statusLabel.text = urls.count ? @"Saved a copy in Files. You can attach it manually." : @"No file was saved. You can still copy the report.";
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.statusLabel.text = @"Save cancelled. You can still copy the report.";
}
- (void)discardSnapshot {
    if (!self.snapshotURL) return;
    [IPDiagnostics removeExportSnapshot:self.snapshotURL];
    self.snapshotURL = nil;
}
- (void)closeReport {
    [self discardSnapshot];
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    [self discardSnapshot];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed ||
        (!self.presentingViewController && !self.navigationController.presentingViewController)) [self discardSnapshot];
}
- (void)dealloc {
    if (_snapshotURL) [IPDiagnostics removeExportSnapshot:_snapshotURL];
}
@end
