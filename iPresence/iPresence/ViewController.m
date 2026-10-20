// Original project by kainograze. Updated by 3h6_1.
#import "ViewController.h"
#import "IPDiscordAuthorization.h"
#import "IPDiagnosticsViewController.h"
#import "../../shared/IPOAuthStore.h"
#import "../../shared/IPDiagnostics.h"
#import <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static NSString * const IPPreferencesPath = @"/var/mobile/Library/Preferences/com.kainograze.iPresence.plist";

@interface ViewController ()
@property(nonatomic, strong) UISwitch *enabledSwitch;
@property(nonatomic, strong) UISwitch *versionSwitch;
@property(nonatomic, strong) UIButton *signInButton;
@property(nonatomic, strong) UIButton *browserSignInButton;
@property(nonatomic, strong) UIButton *signOutButton;
@property(nonatomic, strong) UIButton *cancelSignInButton;
@property(nonatomic, strong) UILabel *accountLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *shareDiagnosticsButton;
@end

@implementation ViewController
- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    return label;
}

- (UIStackView *)row:(NSString *)title toggle:(UISwitch *)toggle {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[[self label:title style:UIFontTextStyleBody], toggle]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 16;
    [toggle setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [toggle setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [toggle addTarget:self action:@selector(save) forControlEvents:UIControlEventValueChanged];
    return row;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [IPDiagnostics recordEvent:@"app_launch" fields:nil];
    self.title = @"iPresence";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:IPPreferencesPath];
    self.enabledSwitch = [UISwitch new];
    id enabled = saved[@"showAsDiscordStatus"];
    self.enabledSwitch.on = [enabled isKindOfClass:NSNumber.class] && [enabled boolValue] && [IPOAuthStore credentials] != nil;
    self.versionSwitch = [UISwitch new];
    id version = saved[@"displayIosVersion"];
    self.versionSwitch.on = ![version isKindOfClass:NSNumber.class] || [version boolValue];
    self.accountLabel = [self label:@"" style:UIFontTextStyleBody];
    self.signInButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.signInButton.configuration = [UIButtonConfiguration filledButtonConfiguration];
    [self.signInButton addTarget:self action:@selector(signIn) forControlEvents:UIControlEventTouchUpInside];
    self.browserSignInButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.browserSignInButton setTitle:@"Sign in using browser" forState:UIControlStateNormal];
    [self.browserSignInButton addTarget:self action:@selector(signInUsingBrowser) forControlEvents:UIControlEventTouchUpInside];
    self.signOutButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.signOutButton setTitle:@"Sign out" forState:UIControlStateNormal];
    [self.signOutButton addTarget:self action:@selector(signOut) forControlEvents:UIControlEventTouchUpInside];
    self.cancelSignInButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.cancelSignInButton setTitle:@"Cancel sign-in" forState:UIControlStateNormal];
    [self.cancelSignInButton addTarget:self action:@selector(cancelSignIn) forControlEvents:UIControlEventTouchUpInside];
    self.statusLabel = [self label:@"Sign in, then enable activity sharing when you’re ready." style:UIFontTextStyleFootnote];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.shareDiagnosticsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.shareDiagnosticsButton setTitle:@"View diagnostics" forState:UIControlStateNormal];
    [self.shareDiagnosticsButton addTarget:self action:@selector(shareDiagnostics) forControlEvents:UIControlEventTouchUpInside];
    UILabel *diagnosticsNotice = [self label:@"Includes recent technical events and app/device versions. Authorization credentials are not recorded. Review, copy, or save a report to send manually." style:UIFontTextStyleFootnote];
    diagnosticsNotice.textColor = UIColor.secondaryLabelColor;
    UILabel *authors = [self label:@"Authors: kainograze · 3h6_1" style:UIFontTextStyleFootnote];
    authors.textColor = UIColor.secondaryLabelColor;
    UILabel *description = [self label:@"Share your music activity with Discord." style:UIFontTextStyleTitle2];
    UILabel *notice = [self label:@"Discord’s minimum presence permission bundle also includes friend and relationship access. iPresence uses it to publish listening activity and does not use friend features. It does not request message, voice, email, or server access. Review Discord’s permissions before approving; you can cancel or revoke access at any time." style:UIFontTextStyleFootnote];
    notice.textColor = UIColor.secondaryLabelColor;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        description, self.accountLabel, notice, self.signInButton, self.browserSignInButton, self.cancelSignInButton, self.signOutButton,
        [self row:@"Share listening activity" toggle:self.enabledSwitch],
        [self row:@"Show iOS version" toggle:self.versionSwitch], self.statusLabel,
        self.shareDiagnosticsButton, diagnosticsNotice, authors
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 24;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48]
    ]];
    [self updateAccount];
    // Never retain the old personal-token integration, including during upgrade.
    if (saved[@"token"] != nil || ([enabled isKindOfClass:NSNumber.class] && [enabled boolValue] && !self.enabledSwitch.isOn)) {
        if (![self persistPreferences]) self.statusLabel.text = @"Could not remove the old settings. Reinstall the rootless package and reopen iPresence.";
    }
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateAccount) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateAccount) name:IPDiscordAuthorizationStateDidChangeNotification object:nil];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)updateAccount {
    BOOL signedIn = [IPOAuthStore credentials] != nil;
    BOOL busy = IPDiscordAuthorization.sharedInstance.busy;
    if (busy) self.statusLabel.text = IPDiscordAuthorization.sharedInstance.progressMessage;
    self.accountLabel.text = signedIn ? @"Signed in with Discord" : @"Not signed in";
    [self.signInButton setTitle:signedIn ? @"Sign in again with Discord" : @"Sign in with Discord" forState:UIControlStateNormal];
    self.signInButton.enabled = !busy;
    self.browserSignInButton.enabled = !busy;
    self.signOutButton.hidden = !signedIn;
    self.signOutButton.enabled = !busy;
    self.cancelSignInButton.hidden = !IPDiscordAuthorization.sharedInstance.canCancelSignIn;
    self.enabledSwitch.enabled = signedIn && !busy;
    self.versionSwitch.enabled = !busy;
    if (!signedIn) self.enabledSwitch.on = NO;
}

- (BOOL)persistPreferences {
    // This allowlist deliberately excludes legacy personal tokens and all OAuth
    // credentials. The secure store is the only OAuth credential authority.
    NSDictionary *settings = @{
        @"showAsDiscordStatus": @(self.enabledSwitch.isOn),
        @"displayIosVersion": @(self.versionSwitch.isOn),
        @"iosVersion": UIDevice.currentDevice.systemVersion
    };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:settings format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    char *temporaryPath = strdup([[IPPreferencesPath stringByAppendingString:@".XXXXXX"] fileSystemRepresentation]);
    int fd = data && temporaryPath ? mkstemp(temporaryPath) : -1;
    BOOL success = fd >= 0;
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    NSUInteger remaining = data.length;
    while (success && remaining) {
        ssize_t written = write(fd, bytes, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { success = NO; break; }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    if (fd >= 0) {
        if (success && fsync(fd) != 0) success = NO;
        if (close(fd) != 0) success = NO;
    }
    if (success) success = rename(temporaryPath, IPPreferencesPath.fileSystemRepresentation) == 0;
    if (!success && temporaryPath) unlink(temporaryPath);
    free(temporaryPath);
    if (success) [IPOAuthStore notifyChanged];
    return success;
}

- (void)save {
    if (self.enabledSwitch.isOn && ![IPOAuthStore credentials]) {
        self.enabledSwitch.on = NO;
        self.statusLabel.text = @"Sign in with Discord before enabling sharing.";
        return;
    }
    if (![self persistPreferences]) {
        self.statusLabel.text = @"Could not save settings. Install the rootless package to share settings with the background service.";
        return;
    }
    self.statusLabel.text = self.enabledSwitch.isOn ? @"Saved. Music activity sharing is on." : @"Saved. Activity sharing is off.";
}

- (void)signIn { [self startSignInUsingBrowser:NO]; }
- (void)signInUsingBrowser { [self startSignInUsingBrowser:YES]; }
- (void)startSignInUsingBrowser:(BOOL)browser {
    if (IPDiscordAuthorization.sharedInstance.busy) return;
    // Remove any legacy token before starting a new OAuth grant.
    if (![self persistPreferences]) {
        self.statusLabel.text = @"Install the rootless package before signing in. This app needs access to its private shared storage.";
        return;
    }
    self.statusLabel.text = @"Complete sign-in with Discord…";
    __weak __typeof__(self) weakSelf = self;
    void (^completion)(BOOL, NSString *) = ^(BOOL success, NSString *message) {
        [weakSelf updateAccount];
        weakSelf.statusLabel.text = success && !weakSelf.enabledSwitch.isOn ? @"Signed in. Turn on “Share listening activity” to begin." : message;
    };
    if (browser) [IPDiscordAuthorization.sharedInstance signInUsingBrowserWithCompletion:completion];
    else [IPDiscordAuthorization.sharedInstance signInWithCompletion:completion];
    [self updateAccount];
}

- (void)signOut {
    if (IPDiscordAuthorization.sharedInstance.busy) return;
    self.enabledSwitch.on = NO;
    BOOL settingsSaved = [self persistPreferences];
    self.statusLabel.text = @"Signing out…";
    __weak __typeof__(self) weakSelf = self;
    [IPDiscordAuthorization.sharedInstance signOutWithCompletion:^(BOOL success, NSString *message) {
        [weakSelf updateAccount];
        weakSelf.statusLabel.text = settingsSaved ? message : @"Sign-out requested, but settings could not be saved. Reopen the rootless installation to check your account.";
    }];
    [self updateAccount];
}
- (void)cancelSignIn {
    [IPDiscordAuthorization.sharedInstance cancelSignIn];
}
- (void)shareDiagnostics {
    if (self.presentedViewController) return;
    NSError *error = nil;
    NSURL *snapshot = [IPDiagnostics exportSnapshotWithError:&error];
    if (!snapshot) {
        self.statusLabel.text = error.localizedDescription ?: @"Could not prepare private diagnostics. Please try again.";
        return;
    }
    IPDiagnosticsViewController *viewer = [[IPDiagnosticsViewController alloc] initWithSnapshotURL:snapshot];
    if (!viewer) {
        [IPDiagnostics removeExportSnapshot:snapshot];
        self.statusLabel.text = @"Could not open the diagnostic report. Please try again.";
        return;
    }
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:viewer];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:YES completion:nil];
}
@end
