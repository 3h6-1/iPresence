#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>

/*
 
 BUILD: must be with clang, xcode cant build dylib for IOS. command:
 
 SDK=$(xcrun --sdk iphoneos --show-sdk-path)
 SRC=$(find . -name "*.m")
 
 xcrun --sdk iphoneos clang \
 -dynamiclib \
 -arch armv7 \
 -arch armv7s\
 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
 -framework UIKit \
 -framework Foundation \
 -framework MediaPlayer \
 -fobjc-arc \
 -ObjC \
 -Wl,-undefined,dynamic_lookup \
 *.m \
 -o iPresence-Springboard-Helper.dylib
 
*/

static void publishState(MPMusicPlayerController *player);

__attribute__((constructor))
static void MediaHelperInit(void)
{
    @autoreleasepool
    {
        MPMusicPlayerController* player = [MPMusicPlayerController iPodMusicPlayer];
        if (!player) return;
        
        [player beginGeneratingPlaybackNotifications];
    
        [NSNotificationCenter.defaultCenter addObserverForName:MPMusicPlayerControllerPlaybackStateDidChangeNotification
            object:player
            queue:nil
            usingBlock:^(NSNotification* n)
            {
                publishState(player);
            }];
    
        [NSNotificationCenter.defaultCenter addObserverForName:MPMusicPlayerControllerNowPlayingItemDidChangeNotification object:player
            queue:nil
            usingBlock:^(NSNotification* n)
            {
                publishState(player);
            }];
        publishState(player);
    }
}

static void publishState(MPMusicPlayerController *player)
{
    if (!player) return;
    
    BOOL musicIsPlaying = (player.playbackState == MPMusicPlaybackStatePlaying);
    MPMediaItem* item = player.nowPlayingItem;
    NSDate* current = [NSDate date];
    
    long long start = ([current timeIntervalSince1970] * 1000) - ([player currentPlaybackTime] * 1000);
    long long end = ([current timeIntervalSince1970] * 1000) + ([[item valueForProperty:MPMediaItemPropertyPlaybackDuration] doubleValue] * 1000);
    
    NSDictionary* currentState;
    
    if (item)
    {
        currentState=
        @{
          @"musicIsPlaying": musicIsPlaying ? @YES : @NO,
          @"metadata" :
              @{
                  @"title": [item valueForProperty:MPMediaItemPropertyTitle] ?: @"",
                  @"album": [item valueForProperty:MPMediaItemPropertyAlbumTitle] ?: @"",
                  @"artist": [item valueForProperty:MPMediaItemPropertyArtist] ?: @"",
                  @"start": [NSNumber numberWithLongLong:start],
                  @"end": [NSNumber numberWithLongLong:end]
                  }
          
          };
    }
    else
    {
        currentState=
        @{
          @"musicIsPlaying": musicIsPlaying ? @YES : @NO,
          @"metadata" :
              @{
                  @"title": @"",
                  @"album": @"",
                  @"artist": @"",
                  @"start": [NSNumber numberWithLongLong:start],
                  @"end": [NSNumber numberWithLongLong:end]
                  }
          
          };
    }

    
    CFPreferencesSetValue(
                          CFSTR("currentState"),
                          (__bridge CFPropertyListRef)currentState,
                          CFSTR("com.kainograze.iPresence-Springboard-Helper"),
                          kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost
                          );
    
    CFPreferencesSynchronize(
                             CFSTR("com.kainograze.iPresence-Springboard-Helper"),
                             kCFPreferencesCurrentUser,
                             kCFPreferencesAnyHost
                             );
    
    CFNotificationCenterPostNotification(
                                         CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.kainograze.iPresence-Springboard-Helper.State-Changed"),
                                         NULL,
                                         NULL,
                                         YES
                                         );
}