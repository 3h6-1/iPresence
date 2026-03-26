//
//  ViewController.h
//  iPresence
//
//  Created by kainograze on 2/4/26.
//  Copyright (c) 2026 kainograze. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface ViewController : UIViewController

- (IBAction)showAsDiscordStatusChanged:(id)sender;

- (IBAction)displayIosVersionChanged:(id)sender;

- (IBAction)saveTokenClicked:(id)sender;

- (void) setDefaultValues;

- (void) writePrefs;

@property (weak, nonatomic) IBOutlet UITextField *tokenTextField;

@property (strong, nonatomic) NSString* iosVersion;

@property (weak, nonatomic) IBOutlet UISwitch *showIosVersionSwitch;

@property (weak, nonatomic) IBOutlet UISwitch *showDiscordStatusSwitch;

@property (strong, nonatomic) NSMutableDictionary* prefs;

@end
