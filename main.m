#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <float.h>
#import <math.h>
#import <signal.h>

@protocol BrightnessClient <NSObject>
- (id)copyPropertyForKey:(NSString *)key NS_RETURNS_RETAINED;
- (BOOL)setProperty:(id)value forKey:(NSString *)key;
@end

static NSString *const MappingKey = @"LEPWMBrightnessNitsMapping";

static BOOL ValidMapping(id value) {
    if (![value isKindOfClass:NSArray.class] || [value count] < 2) return NO;
    double previous = -1;
    for (id pair in value) {
        if (![pair isKindOfClass:NSArray.class] || [pair count] != 2 ||
            ![pair[0] isKindOfClass:NSNumber.class] || ![pair[1] isKindOfClass:NSNumber.class]) return NO;
        double x = [pair[0] doubleValue], y = [pair[1] doubleValue];
        if (!isfinite(x) || !isfinite(y) || x < 0 || y < 0 || x <= previous) return NO;
        previous = x;
    }
    return YES;
}

static NSArray *ConstantMapping(NSArray *original, double nits) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:original.count];
    for (NSArray *pair in original) [result addObject:@[pair[0], @(nits)]];
    return result;
}

static float AudioLevel(const AudioBufferList *input) {
    double energy = 0;
    uint64_t count = 0;
    for (UInt32 b = 0; b < input->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        if (!buffer->mData) continue;
        const float *samples = buffer->mData;
        UInt32 n = buffer->mDataByteSize / sizeof(float);
        for (UInt32 i = 0; i < n; i++) {
            float value = samples[i];
            if (isfinite(value)) energy += (double)value * value;
        }
        count += n;
    }
    return count ? fminf(1, sqrt(energy / count)) : 0;
}

static double BrightnessTarget(double level, double reference) {
    return fmin(1, level / fmax(0.001, reference * 1.8));
}

@interface LogoBeat : NSObject <NSApplicationDelegate, NSMenuItemValidation> {
    _Atomic(float) _peak;
    _Atomic(uint64_t) _callbacks;
}
@property id<BrightnessClient> brightness;
@property NSArray *original;
@property NSArray *lastWritten;
@property NSString *backupPath;
@property NSString *statePath;
@property NSStatusItem *item;
@property NSMenuItem *status;
@property NSTimer *timer;
@property AudioObjectID tap;
@property AudioObjectID device;
@property AudioDeviceIOProcID proc;
@property BOOL running;
@property BOOL brightnessReady;
@property double envelope;
@property double referenceLevel;
@property double lastSound;
@property double lastReport;
@property double nits;
@property dispatch_source_t termination;
- (BOOL)restore;
- (void)stop;
@end

@implementation LogoBeat
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(start)) return self.brightnessReady && !self.running && !self.original;
    if (item.action == @selector(stop)) return self.running || self.original != nil;
    return YES;
}

- (void)updateControls {
    self.item.button.toolTip = self.running
        ? @"Logo Beat is listening to system audio. Stop restores normal logo brightness."
        : @"Logo Beat is stopped. Start to make the Apple logo react to music.";
    [self.item.button setAccessibilityLabel:self.running ? @"Logo Beat, running" : @"Logo Beat, stopped"];
    [self.item.menu update];
}

- (void)showAbout {
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionApplicationIcon: NSApp.applicationIconImage,
        NSAboutPanelOptionCredits: [[NSAttributedString alloc] initWithString:
            @"Music-reactive Apple logo brightness.\n\n"
             "Audio is processed locally, never recorded or transmitted.\n"
             "Stop or Quit restores normal logo brightness.\n"
             "After sleep or locking, choose Start to resume.\n\n"
             "Experimental: uses a private macOS brightness interface.\n"
             "Logo color control is not available. Apple's ambient-light limits remain enabled."]
    }];
}

- (void)error:(NSString *)message {
    NSLog(@"ERROR: %@", message);
    self.status.title = @"Stopped - see error";
    [self updateControls];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Logo Beat";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (BOOL)setupBrightness {
    if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)) {
        [self error:@"CoreBrightness is unavailable. No brightness settings were changed."];
        return NO;
    }
    io_registry_entry_t node = IORegistryEntryFromPath(kIOMainPortDefault,
                                                     "IODeviceTree:/arm-io/pwm1/bklb-backlight");
    if (!node) {
        [self error:@"This Mac does not expose the dedicated Apple logo light."];
        return NO;
    }
    IOObjectRelease(node);
    Class cls = NSClassFromString(@"BrightnessSystemClient");
    id client = [[cls alloc] init];
    if (![client respondsToSelector:@selector(copyPropertyForKey:)] ||
        ![client respondsToSelector:@selector(setProperty:forKey:)]) {
        [self error:@"The private brightness interface has changed. No settings were changed."];
        return NO;
    }
    self.brightness = client;
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.backupPath]) {
        self.original = [NSArray arrayWithContentsOfFile:self.backupPath];
        if (!ValidMapping(self.original) || ![self restore]) {
            [self error:@"Unable to restore the saved logo mapping. The backup has been kept in ~/Library/Application Support/LogoBeat/original-mapping.plist."];
            return NO;
        }
        NSLog(@"Recovered logo mapping from previous run.");
    }
    if (!ValidMapping([self.brightness copyPropertyForKey:MappingKey])) {
        [self error:@"The logo mapping format is unsupported. No settings were changed."];
        return NO;
    }
    return YES;
}

- (BOOL)restore {
    if (!self.original) return YES;
    if (![self.brightness setProperty:self.original forKey:MappingKey] ||
        ![[self.brightness copyPropertyForKey:MappingKey] isEqual:self.original]) {
        NSLog(@"ERROR: Could not restore original logo mapping; keeping backup.");
        return NO;
    }
    NSError *error = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.backupPath] &&
        ![[NSFileManager defaultManager] removeItemAtPath:self.backupPath error:&error]) {
        NSLog(@"ERROR: Could not remove restored mapping backup: %@", error);
        return NO;
    }
    self.original = nil;
    self.lastWritten = nil;
    self.nits = 0;
    NSLog(@"Original logo mapping restored.");
    return YES;
}

- (BOOL)writeNits:(double)nits {
    if (!self.original) {
        self.original = [self.brightness copyPropertyForKey:MappingKey];
        if (!ValidMapping(self.original) || ![self.original writeToFile:self.backupPath atomically:YES]) {
            self.original = nil;
            [self stop];
            [self error:@"Could not save the original logo mapping. No brightness changes were made."];
            return NO;
        }
    }
    NSArray *mapping = ConstantMapping(self.original, nits);
    if (![self.brightness setProperty:mapping forKey:MappingKey]) {
        [self stop];
        [self error:@"macOS rejected logo brightness control. Check the log and saved mapping if restoration failed."];
        return NO;
    }
    self.lastWritten = mapping;
    self.nits = nits;
    return YES;
}

- (BOOL)checkAudio:(OSStatus)code operation:(NSString *)operation {
    if (code == noErr) return YES;
    [self stop];
    [self error:[NSString stringWithFormat:@"%@ failed (Core Audio error %d). Allow Logo Beat in System Settings > Privacy & Security > Screen & System Audio Recording, then choose Start from its menu.", operation, (int)code]];
    return NO;
}

- (void)start {
    if (self.running) return;
    if (!self.brightnessReady) {
        [self error:@"The logo brightness interface is not ready. Quit and reopen Logo Beat to retry initialization."];
        return;
    }
    if (NSProcessInfo.processInfo.lowPowerModeEnabled) {
        [self error:@"Logo Beat is paused in Low Power Mode. Turn it off before starting."];
        return;
    }
    if (![self restore]) {
        [self error:@"The previous logo mapping could not be restored. The saved backup has been kept."];
        return;
    }
    CATapDescription *description = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
    description.name = @"Logo Beat playback level";
    [description setPrivate:YES];
    description.muteBehavior = CATapUnmuted;
    AudioObjectID tap = kAudioObjectUnknown;
    OSStatus code = AudioHardwareCreateProcessTap(description, &tap);
    self.tap = tap;
    if (![self checkAudio:code operation:@"Creating the system audio tap"]) return;
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    AudioObjectPropertyAddress address = {kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMain};
    if (![self checkAudio:AudioObjectGetPropertyData(tap, &address, 0, NULL, &size, &format)
               operation:@"Reading audio format"]) return;
    if (format.mFormatID != kAudioFormatLinearPCM || format.mBitsPerChannel != 32 ||
        !(format.mFormatFlags & kAudioFormatFlagIsFloat) ||
        (format.mFormatFlags & kAudioFormatFlagIsBigEndian)) {
        [self stop];
        [self error:@"The audio tap did not provide supported 32-bit floating-point audio."];
        return;
    }
    NSDictionary *aggregate = @{
        @kAudioAggregateDeviceNameKey: @"Logo Beat (private)",
        @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceTapAutoStartKey: @YES,
        @kAudioAggregateDeviceTapListKey: @[@{
            @kAudioSubTapUIDKey: description.UUID.UUIDString,
            @kAudioSubTapDriftCompensationKey: @YES
        }]
    };
    AudioObjectID device = kAudioObjectUnknown;
    code = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate, &device);
    self.device = device;
    if (![self checkAudio:code operation:@"Creating the private audio device"]) return;
    atomic_store(&_peak, 0);
    atomic_store(&_callbacks, 0);
    AudioDeviceIOProcID proc = NULL;
    code = AudioDeviceCreateIOProcIDWithBlock(&proc, device, NULL,
        ^(const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime,
          AudioBufferList *output, const AudioTimeStamp *outputTime) {
            float level = AudioLevel(input);
            float old = atomic_load(&self->_peak);
            while (old < level && !atomic_compare_exchange_weak(&self->_peak, &old, level)) {}
            atomic_fetch_add(&self->_callbacks, 1);
        });
    self.proc = proc;
    if (![self checkAudio:code operation:@"Creating the audio callback"]) return;
    if (![self checkAudio:AudioDeviceStart(device, proc) operation:@"Starting playback capture"]) return;
    self.running = YES;
    self.envelope = 0;
    self.referenceLevel = 0;
    self.lastSound = NSProcessInfo.processInfo.systemUptime;
    self.lastReport = 0;
    self.timer = [NSTimer timerWithTimeInterval:0.05 target:self selector:@selector(tick)
                                      userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    NSLog(@"Started system playback capture; audio is not recorded or transmitted.");
    self.status.title = @"Listening for music";
    [self updateControls];
}

- (void)tick {
    double now = NSProcessInfo.processInfo.systemUptime;
    float level = atomic_exchange(&_peak, 0);
    if (level > 0.0001) self.lastSound = now;
    if (now - self.lastSound > 1) {
        if (![self restore]) {
            [self stop];
            [self error:@"Unable to restore the normal logo mapping after playback stopped."];
            return;
        }
        self.envelope = 0;
        self.referenceLevel = 0;
        self.status.title = @"Listening - normal logo brightness";
    } else if (level > 0.0001 || self.original) {
        if (level > 0.0001) {
            if (self.referenceLevel == 0) self.referenceLevel = level;
            else self.referenceLevel += (level - self.referenceLevel) * 0.025;
        }
        double target = BrightnessTarget(level, self.referenceLevel);
        self.envelope += (target - self.envelope) * (target > self.envelope ? 0.8 : 0.25);
        double nits = round(12.5 + 287.5 * self.envelope);
        if ((!self.original || fabs(nits - self.nits) >= 2) && ![self writeNits:nits]) return;
        self.status.title = [NSString stringWithFormat:@"Music - logo %.0f nits requested", self.nits];
    }
    if (now - self.lastReport >= 2) {
        self.lastReport = now;
        if (self.lastWritten && ![[self.brightness copyPropertyForKey:MappingKey] isEqual:self.lastWritten]) {
            [self stop];
            [self error:@"The logo mapping changed unexpectedly. Music control has been stopped."];
            return;
        }
        NSDictionary *state = @{@"running": @(self.running), @"callbacks": @(atomic_load(&_callbacks)),
                                @"level": @(level), @"requestedNits": @(self.nits),
                                @"controlsLogo": @(self.original != nil)};
        if (![state writeToFile:self.statePath atomically:YES]) {
            [self stop];
            [self error:@"Could not write Logo Beat's status file."];
        }
    }
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    self.running = NO;
    if (self.proc) {
        OSStatus code = AudioDeviceStop(self.device, self.proc);
        if (code) NSLog(@"ERROR: AudioDeviceStop: %d", (int)code);
        code = AudioDeviceDestroyIOProcID(self.device, self.proc);
        if (code) NSLog(@"ERROR: AudioDeviceDestroyIOProcID: %d", (int)code);
        self.proc = NULL;
    }
    if (self.device) {
        OSStatus code = AudioHardwareDestroyAggregateDevice(self.device);
        if (code) NSLog(@"ERROR: AudioHardwareDestroyAggregateDevice: %d", (int)code);
        self.device = kAudioObjectUnknown;
    }
    if (self.tap) {
        OSStatus code = AudioHardwareDestroyProcessTap(self.tap);
        if (code) NSLog(@"ERROR: AudioHardwareDestroyProcessTap: %d", (int)code);
        self.tap = kAudioObjectUnknown;
    }
    BOOL restored = [self restore];
    self.status.title = restored ? @"Stopped - normal logo brightness" : @"ERROR - restoration failed";
    [self updateControls];
    NSDictionary *state = @{@"running": @NO, @"restored": @(restored)};
    if (![state writeToFile:self.statePath atomically:YES]) NSLog(@"ERROR: Could not write stopped status.");
    NSLog(@"Stopped; restoration %@", restored ? @"succeeded" : @"FAILED");
}

- (void)pause:(NSNotification *)notification {
    [self stop];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/LogoBeat"];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                  attributes:@{NSFilePosixPermissions: @0700} error:&error]) {
        [self error:[NSString stringWithFormat:@"Could not create the local settings directory: %@", error]];
        [NSApp terminate:nil];
        return;
    }
    self.backupPath = [directory stringByAppendingPathComponent:@"original-mapping.plist"];
    self.statePath = [directory stringByAppendingPathComponent:@"status.plist"];
    if (!freopen([[directory stringByAppendingPathComponent:@"app.log"] fileSystemRepresentation], "a", stderr)) {
        [self error:@"Could not open the local app log."];
        [NSApp terminate:nil];
        return;
    }
    NSURL *iconURL = [NSBundle.mainBundle URLForResource:@"LogoBeat" withExtension:@"icns"];
    NSImage *appIcon = iconURL ? [[NSImage alloc] initWithContentsOfURL:iconURL] : nil;
    if (!appIcon) {
        [self error:@"The app icon resource is missing or unreadable. Rebuild Logo Beat before starting."];
        [NSApp terminate:nil];
        return;
    }
    NSApp.applicationIconImage = appIcon;
    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.image = [NSImage imageWithSystemSymbolName:@"waveform"
                                     accessibilityDescription:@"Logo Beat"];
    self.item.button.image.size = NSMakeSize(20, 18);
    self.item.button.image.template = YES;
    NSMenu *menu = [NSMenu new];
    NSMenuItem *heading = [menu addItemWithTitle:@"Logo Beat" action:nil keyEquivalent:@""];
    heading.image = [appIcon copy];
    heading.image.size = NSMakeSize(20, 20);
    self.status = [menu addItemWithTitle:@"Starting..." action:nil keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    for (NSArray *entry in @[@[@"Start", @"start"], @[@"Stop and restore", @"stop"]]) {
        NSMenuItem *item = [menu addItemWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""];
        item.target = self;
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *about = [menu addItemWithTitle:@"About Logo Beat" action:@selector(showAbout) keyEquivalent:@""];
    about.target = self;
    NSMenuItem *quit = [menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    self.item.menu = menu;
    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSString *name in @[NSWorkspaceWillSleepNotification, NSWorkspaceScreensDidSleepNotification,
                             NSWorkspaceSessionDidResignActiveNotification]) {
        [workspace addObserver:self selector:@selector(pause:) name:name object:nil];
    }
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(pause:)
                                                           name:@"com.apple.screenIsLocked" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pause:)
                                                name:NSProcessInfoPowerStateDidChangeNotification object:nil];
    signal(SIGTERM, SIG_IGN);
    self.termination = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(self.termination, ^{ [NSApp terminate:nil]; });
    dispatch_resume(self.termination);
    self.brightnessReady = [self setupBrightness];
    [self updateControls];
    if (self.brightnessReady) [self start];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    [self stop];
    if (self.original) {
        [self error:@"Logo restoration failed. The app will stay open so you can retry Stop and restore. The original mapping backup is preserved."];
        return NSTerminateCancel;
    }
    return NSTerminateNow;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
            NSArray *original = @[@[@0, @0], @[@100, @150], @[@(FLT_MAX), @1000]];
            if (!ValidMapping(original) || ValidMapping(@[@[@1, @2]]) ||
                ValidMapping(@[@[@1, @2], @[@0, @3]]) ||
                ValidMapping(@[@[@0, @(-1)], @[@1, @3]])) return 1;
            NSArray *mapped = ConstantMapping(original, 120);
            if (![mapped isEqual:@[@[@0, @120], @[@100, @120], @[@(FLT_MAX), @120]]]) return 2;
            float samples[] = {0.5, -0.5, 0.5, -0.5};
            AudioBufferList buffer = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof(samples), samples}}};
            if (fabs(AudioLevel(&buffer) - 0.5) > 0.00001) return 3;
            memset(samples, 0, sizeof(samples));
            if (AudioLevel(&buffer) != 0) return 4;
            if (BrightnessTarget(0, 0) != 0 || BrightnessTarget(0.9, 0.2) != 1 ||
                BrightnessTarget(0.2, 0.25) >= BrightnessTarget(0.3, 0.25) ||
                BrightnessTarget(0.3, 0.25) >= 1 ||
                fabs(BrightnessTarget(0.1, 0.1) - BrightnessTarget(0.5, 0.5)) > 0.00001) return 5;
            [NSApplication sharedApplication];
            LogoBeat *delegate = [LogoBeat new];
            delegate.brightnessReady = YES;
            NSMenu *menu = [NSMenu new];
            NSMenuItem *start = [menu addItemWithTitle:@"Start" action:@selector(start) keyEquivalent:@""];
            NSMenuItem *stop = [menu addItemWithTitle:@"Stop" action:@selector(stop) keyEquivalent:@""];
            start.target = delegate;
            stop.target = delegate;
            [menu update];
            if (!start.enabled || stop.enabled) return 6;
            delegate.running = YES;
            [menu update];
            if (start.enabled || !stop.enabled) return 7;
            delegate.running = NO;
            delegate.original = original;
            [menu update];
            if (start.enabled || !stop.enabled) return 8;
            delegate.original = nil;
            delegate.brightnessReady = NO;
            [menu update];
            if (start.enabled || stop.enabled) return 9;
            puts("Self-test passed: brightness, audio processing and native Start/Stop menu validation.");
            return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        LogoBeat *delegate = [LogoBeat new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
