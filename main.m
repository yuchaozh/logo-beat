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
#import "Playful.h"

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

@interface LogoBeat : NSObject <NSApplicationDelegate, NSMenuItemValidation, NSWindowDelegate> {
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
@property double lastReport;
@property double nits;
@property LBAnimator *animator;
@property LBRhythmGame *game;
@property BOOL dancingIcon;
@property double lastIconUpdate;
@property NSWindow *playgroundWindow;
@property LBPlaygroundView *playground;
@property NSButton *gameButton;
@property NSButton *tapButton;
@property dispatch_source_t termination;
- (BOOL)restore;
- (void)stop;
@end

@implementation LogoBeat
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(start)) return self.brightnessReady && !self.running && !self.original;
    if (item.action == @selector(stop)) return self.running || self.original != nil;
    if (item.action == @selector(sendMorse) || item.action == @selector(showGame)) return self.running;
    if (item.action == @selector(cancelMorse)) return self.animator.morseActive;
    if (item.action == @selector(selectMode:)) item.state = item.tag == self.animator.mode ? NSControlStateValueOn : NSControlStateValueOff;
    if (item.action == @selector(selectMood:)) item.state = item.tag == self.animator.mood ? NSControlStateValueOn : NSControlStateValueOff;
    if (item.action == @selector(toggleBreathing)) item.state = self.animator.idleBreathing ? NSControlStateValueOn : NSControlStateValueOff;
    if (item.action == @selector(toggleDancing)) item.state = self.dancingIcon ? NSControlStateValueOn : NSControlStateValueOff;
    return YES;
}

- (void)savePreferences {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:self.animator.mode forKey:@"animationMode"];
    [defaults setInteger:self.animator.mood forKey:@"mood"];
    [defaults setBool:self.animator.idleBreathing forKey:@"idleBreathing"];
    [defaults setBool:self.dancingIcon forKey:@"dancingIcon"];
    [self updateControls];
}

- (void)selectMode:(NSMenuItem *)item {
    self.animator.mode = item.tag;
    [self savePreferences];
}

- (void)selectMood:(NSMenuItem *)item {
    self.animator.mood = item.tag;
    self.animator.mode = item.tag == LBMoodParty ? LBAnimationDJ : LBAnimationVolume;
    [self savePreferences];
}

- (void)toggleBreathing {
    self.animator.idleBreathing = !self.animator.idleBreathing;
    [self savePreferences];
}

- (void)toggleDancing {
    self.dancingIcon = !self.dancingIcon;
    self.item.button.image = self.dancingIcon
        ? LBWaveformIcon(self.animator.audioStrength, NSProcessInfo.processInfo.systemUptime)
        : [NSImage imageWithSystemSymbolName:@"waveform" accessibilityDescription:@"Logo Beat"];
    [self savePreferences];
}

- (void)sendMorse {
    if (!self.running) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Send a secret light message";
    alert.informativeText = @"Use 1-24 English letters, digits, or spaces. Slow, softened Morse pulses temporarily replace the music effect, then resume it. The message is not saved.";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    field.placeholderString = @"HELLO";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Send"];
    [alert addButtonWithTitle:@"Cancel"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert.window setInitialFirstResponder:field];
    if ([alert runModal] != NSAlertFirstButtonReturn || !self.running) return;
    NSError *error = nil;
    if (![self.animator sendMorse:field.stringValue atTime:NSProcessInfo.processInfo.systemUptime error:&error]) {
        NSAlert *invalid = [NSAlert new];
        invalid.messageText = @"Cannot send this message";
        invalid.informativeText = error.localizedDescription;
        [invalid runModal];
    }
    [self updateControls];
}

- (void)cancelMorse {
    [self.animator cancelMorse];
    [self updateControls];
}

- (void)showPlayground {
    if (!self.playgroundWindow) {
        self.playgroundWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 520)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
            backing:NSBackingStoreBuffered defer:NO];
        self.playgroundWindow.title = @"Logo Beat Playground";
        self.playgroundWindow.releasedWhenClosed = NO;
        self.playgroundWindow.delegate = self;
        [self.playgroundWindow center];
        NSView *content = self.playgroundWindow.contentView;
        NSTextField *title = [NSTextField labelWithString:@"Your Mac has rhythm"];
        title.frame = NSMakeRect(20, 484, 560, 28);
        title.font = [NSFont boldSystemFontOfSize:19];
        title.alignment = NSTextAlignmentCenter;
        [content addSubview:title];
        self.playground = [[LBPlaygroundView alloc] initWithFrame:NSMakeRect(20, 104, 560, 374)];
        self.playground.game = self.game;
        __weak LogoBeat *weakSelf = self;
        self.playground.onTap = ^{ [weakSelf tapGame]; };
        [content addSubview:self.playground];
        self.gameButton = [NSButton buttonWithTitle:@"Start rhythm game" target:self action:@selector(toggleGame)];
        self.gameButton.frame = NSMakeRect(70, 54, 220, 32);
        [content addSubview:self.gameButton];
        self.tapButton = [NSButton buttonWithTitle:@"Tap (Space)" target:self action:@selector(tapGame)];
        self.tapButton.frame = NSMakeRect(310, 54, 220, 32);
        [content addSubview:self.tapButton];
        NSTextField *hint = [NSTextField wrappingLabelWithString:
            @"Preview shows requested brightness, not a sensor reading.\nSpace works only in this window. Play music to generate beats."];
        hint.frame = NSMakeRect(20, 8, 560, 40);
        hint.font = [NSFont systemFontOfSize:11];
        hint.textColor = NSColor.secondaryLabelColor;
        hint.alignment = NSTextAlignmentCenter;
        [content addSubview:hint];
    }
    [self updatePlaygroundAtTime:NSProcessInfo.processInfo.systemUptime];
    [NSApp activateIgnoringOtherApps:YES];
    [self.playgroundWindow makeKeyAndOrderFront:nil];
    [self.playgroundWindow makeFirstResponder:self.playground];
}

- (void)showGame {
    if (!self.running) return;
    if (!self.game.active) [self.game start];
    [self showPlayground];
}

- (void)toggleGame {
    if (self.game.active) [self.game stop];
    else if (self.running) [self.game start];
    [self updatePlaygroundAtTime:NSProcessInfo.processInfo.systemUptime];
    [self.playgroundWindow makeFirstResponder:self.playground];
}

- (void)tapGame {
    if (!self.running || !self.game.active) return;
    [self.game tapAtTime:NSProcessInfo.processInfo.systemUptime];
    [self updatePlaygroundAtTime:NSProcessInfo.processInfo.systemUptime];
}

- (void)updatePlaygroundAtTime:(double)time {
    self.gameButton.title = self.game.active ? @"End rhythm game" : @"Start rhythm game";
    self.gameButton.enabled = self.running;
    self.tapButton.enabled = self.running && self.game.active;
    self.playground.time = time;
    self.playground.glow = self.animator.output;
    self.playground.audioStrength = self.animator.audioStrength;
    self.playground.beatAge = time - self.animator.lastBeat;
    self.playground.controlsLight = self.running && self.animator.controlsLight;
    self.playground.caption = self.running
        ? [NSString stringWithFormat:@"%@ / %@ - %@", LBMoodName(self.animator.mood), LBModeName(self.animator.mode),
           self.animator.morseActive ? @"Morse message" : self.animator.controlsLight
           ? [NSString stringWithFormat:@"%.0f nits requested", self.nits] : @"normal logo brightness"]
        : @"Stopped - normal logo brightness";
    if (self.playgroundWindow.visible) self.playground.needsDisplay = YES;
}

- (void)windowWillClose:(NSNotification *)notification {
    [self.game stop];
}

- (void)updateControls {
    self.item.button.toolTip = self.running
        ? @"Logo Beat is listening to system audio. Stop restores normal logo brightness."
        : @"Logo Beat is stopped. Start to make the Apple logo react to music.";
    [self.item.button setAccessibilityLabel:self.running ? @"Logo Beat, running" : @"Logo Beat, stopped"];
    [self.item.menu update];
    [self updatePlaygroundAtTime:NSProcessInfo.processInfo.systemUptime];
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
             "Try mood presets, DJ pulses, idle breathing, Morse messages,\n"
             "and the rhythm game in the Playground.\n\n"
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
    [self.animator resetAtTime:NSProcessInfo.processInfo.systemUptime];
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
    [self advanceWithLevel:level atTime:now];
}

- (void)advanceWithLevel:(float)level atTime:(double)now {
    BOOL wasMorse = self.animator.morseActive;
    [self.animator updateLevel:level atTime:now];
    if (self.animator.detectedBeat) [self.game addBeatAtTime:now];
    [self.game advanceToTime:now];
    if (!self.animator.controlsLight) {
        if (![self restore]) {
            [self stop];
            [self error:@"Unable to restore the normal logo mapping after playback stopped."];
            return;
        }
        self.status.title = @"Listening - normal logo brightness";
    } else {
        double nits = self.animator.requestedNits;
        if ((!self.original || fabs(nits - self.nits) >= 2) && ![self writeNits:nits]) return;
        self.status.title = self.animator.morseActive
            ? [NSString stringWithFormat:@"Morse message - %.0fs left", self.animator.morseRemaining]
            : [NSString stringWithFormat:@"%@ / %@ - %.0f nits requested",
               LBMoodName(self.animator.mood), LBModeName(self.animator.mode), self.nits];
    }
    if (self.dancingIcon && now - self.lastIconUpdate >= 0.1) {
        self.lastIconUpdate = now;
        self.item.button.image = LBWaveformIcon(self.animator.audioStrength, now);
    }
    [self updatePlaygroundAtTime:now];
    if (wasMorse != self.animator.morseActive) [self updateControls];
    if (now - self.lastReport >= 2) {
        self.lastReport = now;
        if (self.lastWritten && ![[self.brightness copyPropertyForKey:MappingKey] isEqual:self.lastWritten]) {
            [self stop];
            [self error:@"The logo mapping changed unexpectedly. Music control has been stopped."];
            return;
        }
        NSDictionary *state = @{@"running": @(self.running), @"callbacks": @(atomic_load(&_callbacks)),
                                @"level": @(level), @"requestedNits": @(self.nits),
                                @"controlsLogo": @(self.original != nil),
                                @"mode": LBModeName(self.animator.mode), @"mood": LBMoodName(self.animator.mood),
                                @"morseActive": @(self.animator.morseActive), @"gameActive": @(self.game.active)};
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
    [self.game stop];
    [self.animator resetAtTime:NSProcessInfo.processInfo.systemUptime];
    if (self.dancingIcon) self.item.button.image = LBWaveformIcon(0, 0);
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
    self.animator = [LBAnimator new];
    self.game = [LBRhythmGame new];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{@"animationMode": @(LBAnimationVolume), @"mood": @(LBMoodParty),
                                 @"idleBreathing": @NO, @"dancingIcon": @YES}];
    NSInteger mode = [defaults integerForKey:@"animationMode"], mood = [defaults integerForKey:@"mood"];
    if (mode < LBAnimationVolume || mode > LBAnimationBreathing || mood < LBMoodChill || mood > LBMoodHeartbeat) {
        NSLog(@"Invalid animation preferences; resetting mode and mood.");
        mode = LBAnimationVolume;
        mood = LBMoodParty;
        [defaults setInteger:mode forKey:@"animationMode"];
        [defaults setInteger:mood forKey:@"mood"];
    }
    self.animator.mode = mode;
    self.animator.mood = mood;
    self.animator.idleBreathing = [defaults boolForKey:@"idleBreathing"];
    self.dancingIcon = [defaults boolForKey:@"dancingIcon"];
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
    NSMenu *modes = [NSMenu new], *moods = [NSMenu new];
    for (NSInteger modeIndex = LBAnimationVolume; modeIndex <= LBAnimationBreathing; modeIndex++) {
        NSMenuItem *option = [modes addItemWithTitle:LBModeName(modeIndex) action:@selector(selectMode:) keyEquivalent:@""];
        option.tag = modeIndex;
        option.target = self;
    }
    for (NSInteger moodIndex = LBMoodChill; moodIndex <= LBMoodHeartbeat; moodIndex++) {
        NSMenuItem *option = [moods addItemWithTitle:LBMoodName(moodIndex) action:@selector(selectMood:) keyEquivalent:@""];
        option.tag = moodIndex;
        option.target = self;
    }
    [menu addItemWithTitle:@"Animation" action:nil keyEquivalent:@""].submenu = modes;
    [menu addItemWithTitle:@"Mood presets" action:nil keyEquivalent:@""].submenu = moods;
    for (NSArray *entry in @[@[@"Breathe when music pauses", @"toggleBreathing"],
                             @[@"Dancing menu-bar icon", @"toggleDancing"],
                             @[@"Open Playground...", @"showPlayground"],
                             @[@"Play rhythm game...", @"showGame"],
                             @[@"Send Morse message...", @"sendMorse"],
                             @[@"Cancel Morse message", @"cancelMorse"]]) {
        NSMenuItem *option = [menu addItemWithTitle:entry[0] action:NSSelectorFromString(entry[1]) keyEquivalent:@""];
        option.target = self;
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

@interface LBTestBrightnessClient : NSObject <BrightnessClient>
@property NSArray *mapping;
@property BOOL rejectWrites;
@end
@implementation LBTestBrightnessClient
- (id)copyPropertyForKey:(NSString *)key {
    return [self.mapping copy];
}
- (BOOL)setProperty:(id)value forKey:(NSString *)key {
    if (self.rejectWrites) return NO;
    self.mapping = [value copy];
    return YES;
}
@end

static BOOL RunControllerTests(void) {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO
                                                 attributes:nil error:&error]) {
        NSLog(@"Controller test cannot create temporary directory: %@", error);
        return NO;
    }
    NSArray *baseline = @[@[@0, @0], @[@100, @150], @[@(FLT_MAX), @1000]];
    LogoBeat *controller = [LogoBeat new];
    LBTestBrightnessClient *client = [LBTestBrightnessClient new];
    client.mapping = baseline;
    controller.brightness = client;
    controller.brightnessReady = YES;
    controller.animator = [LBAnimator new];
    controller.game = [LBRhythmGame new];
    controller.backupPath = [directory stringByAppendingPathComponent:@"original.plist"];
    controller.statePath = [directory stringByAppendingPathComponent:@"status.plist"];
    BOOL passed = YES;
    for (NSInteger mode = LBAnimationVolume; mode <= LBAnimationBreathing; mode++) {
        controller.running = YES;
        controller.animator.mode = mode;
        [controller.animator resetAtTime:0];
        [controller advanceWithLevel:0.1 atTime:0.05];
        passed = passed && controller.original != nil &&
            ![client.mapping isEqual:baseline] &&
            [NSFileManager.defaultManager fileExistsAtPath:controller.backupPath];
        [controller stop];
        passed = passed && controller.original == nil && [client.mapping isEqual:baseline] &&
            ![NSFileManager.defaultManager fileExistsAtPath:controller.backupPath];
    }
    controller.running = YES;
    controller.animator.mode = LBAnimationVolume;
    [controller.animator resetAtTime:0];
    [controller advanceWithLevel:0.1 atTime:0.05];
    [controller advanceWithLevel:0 atTime:2];
    passed = passed && controller.original == nil && [client.mapping isEqual:baseline];
    controller.animator.idleBreathing = YES;
    [controller advanceWithLevel:0 atTime:2.05];
    passed = passed && controller.original != nil;
    [controller.animator sendMorse:@"SOS" atTime:2.1 error:NULL];
    [controller advanceWithLevel:0 atTime:2.15];
    passed = passed && controller.animator.morseActive && controller.original != nil;
    [controller.game start];
    [controller stop];
    passed = passed && !controller.animator.morseActive && !controller.game.active &&
        [client.mapping isEqual:baseline] && controller.original == nil;
    controller.running = YES;
    [controller.animator resetAtTime:0];
    [controller advanceWithLevel:0.1 atTime:0.05];
    client.rejectWrites = YES;
    passed = passed && ![controller restore] && controller.original != nil &&
        [NSFileManager.defaultManager fileExistsAtPath:controller.backupPath];
    client.rejectWrites = NO;
    [controller stop];
    passed = passed && controller.original == nil && [client.mapping isEqual:baseline];
    if (![NSFileManager.defaultManager removeItemAtPath:directory error:&error]) {
        NSLog(@"Controller test cannot remove its temporary files: %@", error);
        return NO;
    }
    if (!passed) NSLog(@"Controller restoration test failed.");
    return passed;
}

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
            if (LBNormalizedAudio(0, 0) != 0 || LBNormalizedAudio(0.9, 0.2) != 1 ||
                LBNormalizedAudio(0.2, 0.25) >= LBNormalizedAudio(0.3, 0.25) ||
                LBNormalizedAudio(0.3, 0.25) >= 1 ||
                fabs(LBNormalizedAudio(0.1, 0.1) - LBNormalizedAudio(0.5, 0.5)) > 0.00001) return 5;
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
            delegate.animator = [LBAnimator new];
            NSMenuItem *dj = [menu addItemWithTitle:@"DJ" action:@selector(selectMode:) keyEquivalent:@""];
            dj.tag = LBAnimationDJ;
            dj.target = delegate;
            delegate.animator.mode = LBAnimationDJ;
            NSMenuItem *morse = [menu addItemWithTitle:@"Morse" action:@selector(sendMorse) keyEquivalent:@""];
            morse.target = delegate;
            NSMenuItem *cancel = [menu addItemWithTitle:@"Cancel" action:@selector(cancelMorse) keyEquivalent:@""];
            cancel.target = delegate;
            [menu update];
            if (dj.state != NSControlStateValueOn || morse.enabled || cancel.enabled) return 11;
            delegate.running = YES;
            [delegate.animator sendMorse:@"E" atTime:0 error:nil];
            [menu update];
            if (!morse.enabled || !cancel.enabled) return 12;
            NSString *previewPath = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : nil;
            if (!LBRunPlayfulTests(previewPath) || !RunControllerTests()) return 10;
            puts("Self-test passed: brightness, audio processing, menu validation, playful animations, Morse and rhythm scoring.");
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
