#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <errno.h>
#import <math.h>
#import <limits.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

// These optional private C APIs are resolved at runtime. Never link MediaRemote
// or hook SpringBoard classes: missing APIs must disable reporting, not SpringBoard.
// ABI reference: https://github.com/theos/headers/blob/master/MediaRemote/MediaRemote.h
// The system framework stays in /System on rootless jailbreaks.
typedef void (*IPGetNowPlayingInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*IPGetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*IPRegisterNotifications)(dispatch_queue_t);

static NSString *const IPStatePath = @"/var/mobile/Library/Preferences/com.kainograze.iPresence-Springboard-Helper.plist";
static CFStringRef const IPStateNotification = CFSTR("com.kainograze.iPresence-Springboard-Helper.State-Changed");

static void *IPMediaRemoteSymbol(void *framework, const char *symbol)
{
    return framework ? dlsym(framework, symbol) : NULL;
}

static NSString *IPMediaRemoteString(void *framework, const char *symbol)
{
    CFStringRef *address = IPMediaRemoteSymbol(framework, symbol);
    if (address && *address && CFGetTypeID(*address) == CFStringGetTypeID()) {
        return (__bridge NSString *)*address;
    }
    // Older releases use the symbol name itself as the dictionary/notification
    // string. Polling still works if a notification name changes on a newer OS.
    return [NSString stringWithUTF8String:symbol];
}

static double IPNumber(id value, double fallback)
{
    if (![value isKindOfClass:NSNumber.class]) return fallback;
    double number = [value doubleValue];
    return isfinite(number) ? number : fallback;
}

static NSString *IPString(id value)
{
    return [value isKindOfClass:NSString.class] ? value : @"";
}

// Keep media transformation separate from the asynchronous queries. Timestamps
// are Unix milliseconds for the daemon; omit them for live/unknown-length media.
static NSDictionary *IPState(NSDictionary *info, NSDictionary *keys, BOOL playing, double now)
{
    NSString *title = IPString(info[keys[@"title"]]);
    NSString *artist = IPString(info[keys[@"artist"]]);
    BOOL hasMedia = title.length > 0 || artist.length > 0;
    NSMutableDictionary *metadata = [@{
        @"title": title,
        @"album": IPString(info[keys[@"album"]]),
        @"artist": artist
    } mutableCopy];
    double duration = IPNumber(info[keys[@"duration"]], 0);
    double elapsed = IPNumber(info[keys[@"elapsed"]], -1);
    double rate = IPNumber(info[keys[@"rate"]], 1);
    // Reject nonsensical values before floating-point-to-integer conversion.
    if (rate <= 0 || rate > 16) rate = 1;
    if (playing && hasMedia && duration > 0 && duration < 31536000 && elapsed >= 0) {
        id timestamp = info[keys[@"timestamp"]];
        if ([timestamp isKindOfClass:NSDate.class]) {
            double sinceSample = now - [timestamp timeIntervalSince1970];
            if (isfinite(sinceSample) && sinceSample > 0) elapsed += sinceSample * rate;
        }
        elapsed = fmin(duration, fmax(0, elapsed));
        metadata[@"start"] = @((long long)llround((now - elapsed / rate) * 1000));
        metadata[@"end"] = @((long long)llround((now + (duration - elapsed) / rate) * 1000));
    }
    return @{@"musicIsPlaying": @(playing && hasMedia), @"metadata": metadata, @"updatedAt": @(now)};
}

static void IPPublishState(NSDictionary *state)
{
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"currentState": state}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (!data) return;

    // SpringBoard runs as mobile. mkstemp creates a mobile-owned 0600 file in
    // the same directory, and rename atomically replaces the old state. Avoid
    // cfprefsd caching because the daemon reads this plist directly.
    char temporaryPath[PATH_MAX];
    int length = snprintf(temporaryPath, sizeof(temporaryPath), "%s.XXXXXX", IPStatePath.fileSystemRepresentation);
    if (length < 0 || (size_t)length >= sizeof(temporaryPath)) return;
    int descriptor = mkstemp(temporaryPath);
    BOOL success = descriptor >= 0;
    if (success) {
        const uint8_t *bytes = data.bytes;
        NSUInteger remaining = data.length;
        while (remaining > 0) {
            ssize_t count = write(descriptor, bytes, remaining);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) { success = NO; break; }
            bytes += count;
            remaining -= (NSUInteger)count;
        }
        if (close(descriptor) != 0) success = NO;
        if (success) success = rename(temporaryPath, IPStatePath.fileSystemRepresentation) == 0;
        if (!success) unlink(temporaryPath);
    }
    static BOOL reportedFailure = NO;
    if (!success) {
        if (!reportedFailure) NSLog(@"[iPresence] Unable to write now-playing state: %s", strerror(errno));
        reportedFailure = YES;
        return;
    }
    reportedFailure = NO;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        IPStateNotification, NULL, NULL, YES);
}

@interface IPNowPlayingObserver : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, copy) NSDictionary *keys;
@property(nonatomic, copy) NSArray *observers;
@property(nonatomic) IPGetNowPlayingInfo getInfo;
@property(nonatomic) IPGetIsPlaying getPlaying;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL inFlight;
@property(nonatomic) BOOL refreshPending;
- (void)start;
- (void)requestRefresh;
@end

@implementation IPNowPlayingObserver
- (void)start
{
    // Keep the framework loaded for the life of the injected library; callbacks
    // and exported constant pointers may outlive this method.
    void *framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL);
    self.queue = dispatch_queue_create("com.kainograze.iPresence.media", DISPATCH_QUEUE_SERIAL);
    self.getInfo = (IPGetNowPlayingInfo)IPMediaRemoteSymbol(framework, "MRMediaRemoteGetNowPlayingInfo");
    self.getPlaying = (IPGetIsPlaying)IPMediaRemoteSymbol(framework, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    if (!self.getInfo) {
        NSLog(@"[iPresence] MediaRemote is unavailable; now-playing reporting is disabled.");
        dispatch_async(self.queue, ^{
            IPPublishState(@{@"musicIsPlaying": @NO, @"metadata": @{}, @"updatedAt": @([NSDate date].timeIntervalSince1970)});
        });
        return;
    }
    self.keys = @{
        @"title": IPMediaRemoteString(framework, "kMRMediaRemoteNowPlayingInfoTitle"),
        @"album": IPMediaRemoteString(framework, "kMRMediaRemoteNowPlayingInfoAlbum"),
        @"artist": IPMediaRemoteString(framework, "kMRMediaRemoteNowPlayingInfoArtist"),
        @"duration": IPMediaRemoteString(framework, "kMRMediaRemoteNowPlayingInfoDuration"),
        @"elapsed": IPMediaRemoteString(framework, "kMRMediaRemoteNowPlayingInfoElapsedTime"),
        @"rate": IPMediaRemoteString(framework, "kMRMediaRemoteNowPlayingInfoPlaybackRate"),
        @"timestamp": IPMediaRemoteString(framework, "kMRMediaRemoteNowPlayingInfoTimestamp")
    };
    IPRegisterNotifications registerNotifications = (IPRegisterNotifications)IPMediaRemoteSymbol(framework, "MRMediaRemoteRegisterForNowPlayingNotifications");
    NSMutableArray *observers = [NSMutableArray array];
    for (NSString *symbol in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification"]) {
        id token = [NSNotificationCenter.defaultCenter addObserverForName:IPMediaRemoteString(framework, symbol.UTF8String)
            object:nil queue:nil usingBlock:^(__unused NSNotification *notification) {
                dispatch_async(self.queue, ^{ [self requestRefresh]; });
            }];
        [observers addObject:token];
    }
    self.observers = observers;
    if (registerNotifications) registerNotifications(dispatch_get_main_queue());

    // Recover missed notifications/media-server restarts, and let the daemon
    // detect a stopped helper through updatedAt. All state stays on one queue.
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(self.timer, DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(self.timer, ^{ [self requestRefresh]; });
    dispatch_resume(self.timer);
}

- (void)finishInformation:(NSDictionary *)information playing:(BOOL)playing generation:(NSUInteger)generation timedOut:(BOOL)timedOut
{
    if (!self.inFlight || generation != self.generation) return;
    self.inFlight = NO;
    // Discard a result superseded by a track/playback notification. On timeout
    // clear stale presence immediately, even if another refresh is queued.
    if (!self.refreshPending || timedOut) {
        IPPublishState(IPState(information, self.keys, playing, [NSDate date].timeIntervalSince1970));
    }
    if (self.refreshPending) {
        self.refreshPending = NO;
        [self requestRefresh];
    }
}

- (void)requestRefresh
{
    if (self.inFlight) { self.refreshPending = YES; return; }
    self.inFlight = YES;
    NSUInteger generation = ++self.generation;
    __block NSDictionary *information = @{};
    __block BOOL playing = NO;
    __block NSUInteger remaining = self.getPlaying ? 2 : 1;
    void (^finishedPart)(void) = ^{
        if (--remaining != 0) return;
        if (!self.getPlaying) playing = IPNumber(information[self.keys[@"rate"]], 0) > 0;
        [self finishInformation:information playing:playing generation:generation timedOut:NO];
    };
    self.getInfo(self.queue, ^(CFDictionaryRef result) {
        if (!self.inFlight || generation != self.generation) return;
        if (result && CFGetTypeID(result) == CFDictionaryGetTypeID()) information = [(__bridge NSDictionary *)result copy];
        finishedPart();
    });
    if (self.getPlaying) {
        self.getPlaying(self.queue, ^(Boolean result) {
            if (!self.inFlight || generation != self.generation) return;
            playing = result;
            finishedPart();
        });
    }
    // Never block SpringBoard or leave an old song advertised if a private API
    // stops delivering callbacks. Late callbacks are ignored by generation.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), self.queue, ^{
        [self finishInformation:@{} playing:NO generation:generation timedOut:YES];
    });
}
@end

__attribute__((constructor))
static void IPMediaHelperInit(void)
{
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        // Defer work until SpringBoard's main loop runs; constructors must not
        // synchronously initialize media services while dyld is loading images.
        dispatch_async(dispatch_get_main_queue(), ^{
            static IPNowPlayingObserver *observer;
            observer = [IPNowPlayingObserver new];
            [observer start];
        });
    }
}
