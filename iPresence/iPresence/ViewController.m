//
//  ViewController.m
//  iPresence
//
//  Created by kainograze on 2/4/26.
//  Copyright (c) 2026 kainograze. All rights reserved.
//

// to build, run on project dir:
// xcodebuild clean build CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

#import "ViewController.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.iosVersion = [[[UIDevice currentDevice].systemVersion componentsSeparatedByString:@"."] firstObject];
    
    self.prefs = [[NSMutableDictionary alloc]init];
    NSDictionary* loadedPrefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.kainograze.iPresence.plist"];
    
    if (loadedPrefs)
    {
        self.prefs = [loadedPrefs mutableCopy];
    }
    else
    {
        NSLog(@"prefs is null, setting value");
        [self setDefaultValues];
    }
    
    NSLog(@"SHOW AS DC STATUS: %@", self.prefs [@"showAsDiscordStatus"]);
    
    [self.showDiscordStatusSwitch setOn:[self.prefs[@"showAsDiscordStatus"] boolValue] animated:YES];
    [self.showIosVersionSwitch setOn:[self.prefs[@"displayIosVersion"] boolValue] animated:YES];
    [self.tokenTextField setText:self.prefs[@"token"]];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (IBAction)showAsDiscordStatusChanged:(UISwitch*)sender
{
    NSNumber* v = self.showDiscordStatusSwitch.isOn ? @YES : @NO;
    
    [self.prefs setValue:v forKey:@"showAsDiscordStatus"];
    [self writePrefs];
    
    CFNotificationCenterPostNotification(
                                         CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.kainograze.iPresence.settingsChanged"),
                                         NULL,
                                         NULL,
                                         YES
                                         );
}

- (IBAction)displayIosVersionChanged:(UISwitch*)sender
{
    NSLog(@"display ios version changed");
    
    NSNumber* v = self.showIosVersionSwitch.isOn ? @YES : @NO;
    NSLog(@"display ios version:  %@", v);
    
    [self.prefs setValue:v forKey:@"displayIosVersion"];
    [self writePrefs];
    
    CFNotificationCenterPostNotification(
                                         CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.kainograze.iPresence.settingsChanged"),
                                         NULL,
                                         NULL,
                                         YES
                                         );
}

- (IBAction)saveTokenClicked:(id)sender
{
    NSLog(@"save token clicked");
    
    NSString* tokenVal = [self.tokenTextField text];
    
    [self.prefs setValue:tokenVal forKey:@"token"];
    [self writePrefs];
    
    CFNotificationCenterPostNotification(
                                         CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.kainograze.iPresence.settingsChanged"),
                                         NULL,
                                         NULL,
                                         YES
                                         );
}

- (void) setDefaultValues
{
//    self.prefs[@"showAsDiscordStatus"] = @NO;
//    [self.prefs setObject:@NO forKey:@"showAsDiscordStatus"];
//    self.prefs[@"displayIosVersion"] = @YES;
//    self.prefs[@"token"] = @"";
//    self.prefs[@"iosVersion"] = self.iosVersion;
    
    [self.prefs addEntriesFromDictionary:@{@"showAsDiscordStatus": @NO, @"displayIosVersion": @YES, @"token": @"", @"iosVersion": self.iosVersion}];
    NSLog(@"values: %@", [self.prefs description]);
    
    [self writePrefs];
}

- (void) writePrefs
{
    [self.prefs writeToFile:@"/var/mobile/Library/Preferences/com.kainograze.iPresence.plist" atomically:YES];
}

@end
