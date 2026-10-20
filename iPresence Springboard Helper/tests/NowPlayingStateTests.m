// Original project by kainograze. Updated by 3h6_1.
// Host-side transformation regression tests; no device/private frameworks needed.
// The injected library constructor is a no-op outside SpringBoard.
#import "../iPresence Springboard Helper/iPresence_Springboard_Helper.m"

static void Check(BOOL condition, NSString *description)
{
    if (!condition) {
        NSLog(@"FAIL: %@", description);
        exit(1);
    }
}

int main(void)
{
    @autoreleasepool {
        Check(IPMediaRemoteSymbol(NULL, "MRMediaRemoteGetNowPlayingInfo") == NULL,
              @"missing framework cannot resolve or call a private function");
        Check([IPMediaRemoteString(NULL, "kMRMediaRemoteNowPlayingInfoTitle") isEqualToString:@"kMRMediaRemoteNowPlayingInfoTitle"],
              @"missing exported string falls back to its historical literal name");
        void *host = dlopen(NULL, RTLD_LAZY);
        Check(IPMediaRemoteSymbol(host, "IPresenceMissingSymbolForTest") == NULL,
              @"missing symbol in an available image is safely optional");
        Check([IPMediaRemoteString(host, "IPresenceMissingStringForTest") isEqualToString:@"IPresenceMissingStringForTest"],
              @"missing notification export has a safe string fallback");
        if (host) dlclose(host);
        NSDictionary *keys = @{@"title": @"title", @"album": @"album", @"artist": @"artist",
                               @"duration": @"duration", @"elapsed": @"elapsed", @"rate": @"rate", @"timestamp": @"timestamp"};
        NSDictionary *track = @{@"title": @"Track", @"artist": @"Artist", @"duration": @300, @"elapsed": @60,
                                @"rate": @1, @"timestamp": [NSDate dateWithTimeIntervalSince1970:990]};
        NSDictionary *state = IPState(track, keys, YES, 1000);
        Check([state[@"musicIsPlaying"] boolValue], @"active media is published");
        Check([state[@"metadata"][@"start"] longLongValue] == 930000, @"sample timestamp advances elapsed time");
        Check([state[@"metadata"][@"end"] longLongValue] == 1230000, @"end time uses remaining duration, not full duration");
        Check([state[@"updatedAt"] doubleValue] == 1000, @"state carries heartbeat timestamp");

        state = IPState(track, keys, NO, 1000);
        Check(![state[@"musicIsPlaying"] boolValue] && !state[@"metadata"][@"start"], @"pause clears active state and timestamps");
        state = IPState(@{}, keys, YES, 1000);
        Check(![state[@"musicIsPlaying"] boolValue], @"missing media cannot advertise a song");
        state = IPState(@{@"title": @42, @"artist": NSNull.null, @"duration": @"bad", @"elapsed": @0}, keys, YES, 1000);
        Check(![state[@"musicIsPlaying"] boolValue], @"malformed metadata does not crash or activate presence");
        state = IPState(@{@"title": @"Live radio", @"duration": @0, @"elapsed": @0}, keys, YES, 1000);
        Check([state[@"musicIsPlaying"] boolValue] && !state[@"metadata"][@"end"], @"live media does not receive a fabricated end time");
        state = IPState(@{@"title": @"Track", @"duration": @100, @"elapsed": @20, @"rate": @2}, keys, YES, 1000);
        Check([state[@"metadata"][@"start"] longLongValue] == 990000 && [state[@"metadata"][@"end"] longLongValue] == 1040000,
              @"non-unit playback rate scales remaining time");
        state = IPState(@{@"title": @"Track", @"duration": @(INFINITY), @"elapsed": @20}, keys, YES, 1000);
        Check(!state[@"metadata"][@"end"], @"nonfinite duration cannot enter timestamp conversion");
        state = IPState(@{@"title": @"Track", @"duration": @100, @"elapsed": @200, @"rate": @(NAN)}, keys, YES, 1000);
        Check([state[@"metadata"][@"end"] longLongValue] == 1000000, @"elapsed time is clamped to track duration");
        NSLog(@"Now-playing transformation tests passed.");
    }
    return 0;
}
