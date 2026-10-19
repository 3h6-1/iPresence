#import "ViewController.h"
#import <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString * const IPPreferencesPath = @"/var/mobile/Library/Preferences/com.kainograze.iPresence.plist";

@interface ViewController ()
@property(nonatomic, strong) UITextField *tokenField;
@property(nonatomic, strong) UISwitch *enabledSwitch;
@property(nonatomic, strong) UISwitch *versionSwitch;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) NSMutableDictionary *preferences;
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
    [toggle addTarget:self action:@selector(save) forControlEvents:UIControlEventValueChanged];
    return row;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"iPresence";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    // Restrict a legacy settings file before displaying it. Do not follow a symlink.
    int existing = open(IPPreferencesPath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    BOOL preferencesPrivate = existing < 0 && errno == ENOENT;
    if (existing >= 0) {
        struct stat attributes;
        preferencesPrivate = fstat(existing, &attributes) == 0 && S_ISREG(attributes.st_mode) &&
            attributes.st_uid == getuid() && fchmod(existing, 0600) == 0;
        close(existing);
    }
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:IPPreferencesPath];
    self.preferences = [@{@"showAsDiscordStatus": @NO, @"displayIosVersion": @YES, @"token": @""} mutableCopy];
    if ([saved isKindOfClass:NSDictionary.class]) [self.preferences addEntriesFromDictionary:saved];
    self.enabledSwitch = [UISwitch new];
    id enabled = self.preferences[@"showAsDiscordStatus"];
    self.enabledSwitch.on = [enabled respondsToSelector:@selector(boolValue)] && [enabled boolValue];
    self.versionSwitch = [UISwitch new];
    id version = self.preferences[@"displayIosVersion"];
    self.versionSwitch.on = [version respondsToSelector:@selector(boolValue)] && [version boolValue];
    self.tokenField = [UITextField new];
    self.tokenField.borderStyle = UITextBorderStyleRoundedRect;
    self.tokenField.placeholder = @"Discord token";
    self.tokenField.secureTextEntry = YES;
    self.tokenField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.tokenField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.tokenField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.tokenField.textContentType = UITextContentTypePassword;
    self.tokenField.accessibilityLabel = @"Discord token";
    self.tokenField.text = [self.preferences[@"token"] isKindOfClass:NSString.class] ? self.preferences[@"token"] : @"";
    self.tokenField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.tokenField.adjustsFontForContentSizeCategory = YES;
    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    save.configuration = [UIButtonConfiguration filledButtonConfiguration];
    [save setTitle:@"Save settings" forState:UIControlStateNormal];
    [save addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside];
    self.statusLabel = [self label:@"Install through your rootless package manager, then respring to start the media helper." style:UIFontTextStyleFootnote];
    if (!preferencesPrivate) self.statusLabel.text = @"Save settings to replace the existing preferences with a private copy. If saving fails, reinstall through your rootless package manager.";
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    UILabel *description = [self label:@"Share the current music activity from your device with Discord." style:UIFontTextStyleTitle2];
    UILabel *notice = [self label:@"This preserves the original project's unofficial user-token integration. Discord does not support automated user accounts and may disable them. The token is stored locally with access restricted to the mobile user." style:UIFontTextStyleFootnote];
    notice.textColor = UIColor.secondaryLabelColor;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[description, [self row:@"Share listening activity" toggle:self.enabledSwitch], [self row:@"Show iOS version" toggle:self.versionSwitch], self.tokenField, save, self.statusLabel, notice]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 24;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48],
        [self.tokenField.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ]];
}

- (void)save {
    NSString *token = [(self.tokenField.text ?: @"") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (self.enabledSwitch.isOn && token.length == 0) {
        self.statusLabel.text = @"Enter a token before enabling activity sharing.";
        self.enabledSwitch.on = NO;
        return;
    }
    self.preferences[@"token"] = token;
    self.preferences[@"showAsDiscordStatus"] = @(self.enabledSwitch.isOn);
    self.preferences[@"displayIosVersion"] = @(self.versionSwitch.isOn);
    self.preferences[@"iosVersion"] = UIDevice.currentDevice.systemVersion;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:self.preferences format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    // mkstemp creates mode 0600 before any token bytes are written; rename is atomic.
    char *temporaryPath = strdup([[IPPreferencesPath stringByAppendingString:@".XXXXXX"] fileSystemRepresentation]);
    int fd = data && temporaryPath ? mkstemp(temporaryPath) : -1;
    BOOL success = fd >= 0;
    const unsigned char *bytes = data.bytes;
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
    if (!success) {
        self.statusLabel.text = @"Could not save settings. Install the rootless .deb; a sandboxed or sideloaded app cannot access the shared preferences.";
        return;
    }
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.kainograze.iPresence.settingsChanged"), NULL, NULL, YES);
    [self.view endEditing:YES];
    self.statusLabel.text = self.enabledSwitch.isOn ? @"Saved. Play music to share your activity." : @"Saved. Activity sharing is off.";
}
@end
