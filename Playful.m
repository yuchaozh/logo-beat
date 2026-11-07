#import "Playful.h"
#import <math.h>

double LBNormalizedAudio(double level, double reference) {
    return fmin(1, fmax(0, level) / fmax(0.001, reference * 1.8));
}

NSString *LBModeName(LBAnimationMode mode) {
    switch (mode) {
        case LBAnimationVolume: return @"Volume";
        case LBAnimationDJ: return @"DJ pulses";
        case LBAnimationBreathing: return @"Breathing Mac";
    }
    return @"Unknown mode";
}

NSString *LBMoodName(LBMood mood) {
    switch (mood) {
        case LBMoodChill: return @"Chill";
        case LBMoodParty: return @"Party";
        case LBMoodHeartbeat: return @"Heartbeat";
    }
    return @"Unknown mood";
}

NSImage *LBWaveformIcon(double level, double time) {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(20, 18) flipped:NO
                           drawingHandler:^BOOL(NSRect rect) {
        [NSColor.blackColor setFill];
        for (int i = 0; i < 5; i++) {
            double bounce = 0.35 + 0.65 * (0.5 + 0.5 * sin(time * 6 + i * 1.4));
            double height = 3 + 13 * fmin(1, fmax(0, level)) * bounce;
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(i * 4, (18 - height) / 2, 2.5, height)
                                              xRadius:1.25 yRadius:1.25] fill];
        }
        return YES;
    }];
    image.template = YES;
    [image setAccessibilityDescription:@"Logo Beat dancing waveform"];
    return image;
}

@interface LBMorseStep : NSObject
@property BOOL lit;
@property NSUInteger units;
@end
@implementation LBMorseStep
@end

static NSArray<LBMorseStep *> *EncodeMorse(NSString *text, NSError **error) {
    NSString *message = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                              @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 "];
    if (message.length == 0 || message.length > 24 ||
        [message rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) {
        if (error) *error = [NSError errorWithDomain:@"LogoBeat.Morse" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"Use 1-24 characters: English letters, digits, and spaces only."
        }];
        return nil;
    }
    message = message.uppercaseString;
    NSArray<NSString *> *codes = @[@".-", @"-...", @"-.-.", @"-..", @".", @"..-.", @"--.",
        @"....", @"..", @".---", @"-.-", @".-..", @"--", @"-.", @"---", @".--.", @"--.-",
        @".-.", @"...", @"-", @"..-", @"...-", @".--", @"-..-", @"-.--", @"--..",
        @"-----", @".----", @"..---", @"...--", @"....-", @".....", @"-....", @"--...",
        @"---..", @"----."];
    NSMutableArray<LBMorseStep *> *steps = [NSMutableArray new];
    void (^append)(BOOL, NSUInteger) = ^(BOOL lit, NSUInteger units) {
        LBMorseStep *step = [LBMorseStep new];
        step.lit = lit;
        step.units = units;
        [steps addObject:step];
    };
    for (NSUInteger i = 0; i < message.length; i++) {
        unichar character = [message characterAtIndex:i];
        if (character == ' ') continue;
        NSUInteger index = character >= 'A' ? character - 'A' : 26 + character - '0';
        NSString *code = codes[index];
        for (NSUInteger symbol = 0; symbol < code.length; symbol++) {
            append(YES, [code characterAtIndex:symbol] == '.' ? 1 : 3);
            if (symbol + 1 < code.length) append(NO, 1);
        }
        if (i + 1 < message.length) {
            BOOL wordGap = [message characterAtIndex:i + 1] == ' ';
            append(NO, wordGap ? 7 : 3);
        }
    }
    return steps;
}

@interface LBAnimator ()
@property double output;
@property double audioStrength;
@property double lastBeat;
@property BOOL detectedBeat;
@property BOOL controlsLight;
@property double reference;
@property double previousLevel;
@property double lastSound;
@property double previousTime;
@property double origin;
@property NSArray<LBMorseStep *> *morse;
@property double morseStart;
@property double morseDuration;
@property double morseRemaining;
@end

@implementation LBAnimator
- (instancetype)init {
    if ((self = [super init])) {
        _mood = LBMoodParty;
        [self resetAtTime:0];
    }
    return self;
}

- (void)resetAtTime:(double)time {
    self.output = 0;
    self.audioStrength = 0;
    self.reference = 0;
    self.previousLevel = 0;
    self.lastSound = time - 2;
    self.previousTime = time;
    self.origin = time;
    self.lastBeat = -INFINITY;
    self.detectedBeat = NO;
    self.controlsLight = NO;
    [self cancelMorse];
}

- (double)requestedNits {
    double ceiling = self.mood == LBMoodChill ? 180 : self.mood == LBMoodHeartbeat ? 240 : 300;
    return round(12.5 + (ceiling - 12.5) * self.output);
}

- (BOOL)morseActive {
    return self.morse.count > 0;
}

- (BOOL)sendMorse:(NSString *)text atTime:(double)time error:(NSError **)error {
    NSArray<LBMorseStep *> *steps = EncodeMorse(text, error);
    if (!steps) return NO;
    self.morse = steps;
    self.morseStart = time;
    self.morseDuration = 0;
    for (LBMorseStep *step in steps) self.morseDuration += step.units * 0.65;
    self.morseRemaining = self.morseDuration;
    return YES;
}

- (void)cancelMorse {
    self.morse = nil;
    self.morseRemaining = 0;
    self.morseDuration = 0;
}

- (void)updateLevel:(double)level atTime:(double)time {
    double dt = fmin(0.2, fmax(0, time - self.previousTime));
    self.previousTime = time;
    level = isfinite(level) ? fmin(1, fmax(0, level)) : 0;
    self.detectedBeat = NO;
    if (level > 0.0001) {
        double cooldown = self.mood == LBMoodHeartbeat ? 1.2 : 0.7;
        if (level > fmax(0.001, self.reference * 1.35) &&
            level > self.previousLevel * 1.15 && time - self.lastBeat >= cooldown) {
            self.lastBeat = time;
            self.detectedBeat = YES;
        }
        self.lastSound = time;
        if (self.reference == 0) self.reference = level;
        else self.reference += (level - self.reference) * (1 - exp(-dt / 2));
    }
    self.previousLevel = level;
    BOOL silent = time - self.lastSound > 1;
    self.audioStrength = silent ? 0 : LBNormalizedAudio(level, self.reference);
    self.controlsLight = !silent || self.idleBreathing || self.mode == LBAnimationBreathing;
    double target = self.audioStrength;
    if (silent) {
        self.reference = 0;
        target = self.controlsLight ? 0.08 + 0.42 * (0.5 - 0.5 * cos((time - self.origin) * 2 * M_PI / 5)) : 0;
    } else if (self.mood == LBMoodHeartbeat) {
        double age = time - self.lastBeat;
        double pulse = exp(-age / 0.25) + 0.7 * exp(-pow((age - 0.4) / 0.16, 2));
        target = fmin(1, 0.1 + self.audioStrength * 0.2 + pulse * 0.7);
    } else if (self.mode == LBAnimationDJ) {
        target = fmin(1, 0.1 + self.audioStrength * 0.3 + 0.7 * exp(-(time - self.lastBeat) / 0.35));
    }
    if (self.morseActive) {
        double elapsed = fmax(0, time - self.morseStart);
        self.morseRemaining = fmax(0, self.morseDuration - elapsed);
        if (elapsed >= self.morseDuration) {
            [self cancelMorse];
        } else {
            for (LBMorseStep *step in self.morse) {
                double duration = step.units * 0.65;
                if (elapsed < duration) {
                    target = step.lit ? 0.85 : 0.08;
                    self.controlsLight = YES;
                    break;
                }
                elapsed -= duration;
            }
        }
    }
    double smoothing = self.mood == LBMoodChill ? (target > self.output ? 0.25 : 0.65) : 0.12;
    double delta = (target - self.output) * (1 - exp(-dt / smoothing));
    // Bound the transition rate even for DJ and Morse effects; never hard-strobe.
    self.output = fmin(1, fmax(0, self.output + fmin(dt * 1.6, fmax(-dt * 1.6, delta))));
    if (!self.controlsLight) self.output = 0;
}
@end

@interface LBRhythmGame ()
@property BOOL active;
@property NSInteger score;
@property NSInteger combo;
@property NSInteger hits;
@property NSInteger misses;
@property NSString *feedback;
@property NSMutableArray<NSNumber *> *beats;
@property NSNumber *earlyTap;
@end

@implementation LBRhythmGame
- (instancetype)init {
    if ((self = [super init])) {
        _beats = [NSMutableArray new];
        _feedback = @"Start the game, play music, and tap Space on the beat.";
    }
    return self;
}
- (void)start {
    self.active = YES;
    self.score = self.combo = self.hits = self.misses = 0;
    [self.beats removeAllObjects];
    self.earlyTap = nil;
    self.feedback = @"Tap Space when the ring swells with a detected beat.";
}
- (void)stop {
    self.active = NO;
    [self.beats removeAllObjects];
    self.earlyTap = nil;
    self.feedback = @"Game paused. Your score stays until the next game.";
}
- (void)miss {
    self.misses++;
    self.combo = 0;
    self.feedback = @"Miss - listen for the next beat!";
}
- (void)hitWithOffset:(double)offset {
    BOOL perfect = fabs(offset) <= 0.09;
    self.hits++;
    self.combo++;
    self.score += (perfect ? 100 : 60) + MIN(self.combo, 10) * 5;
    self.feedback = perfect ? @"Perfect!" : @"Nice timing!";
}
- (void)advanceToTime:(double)time {
    if (!self.active) return;
    while (self.beats.count && time - self.beats.firstObject.doubleValue > 0.22) {
        [self.beats removeObjectAtIndex:0];
        [self miss];
    }
    if (self.earlyTap && time - self.earlyTap.doubleValue > 0.22) {
        self.earlyTap = nil;
        [self miss];
    }
}
- (void)addBeatAtTime:(double)time {
    if (!self.active) return;
    [self advanceToTime:time];
    if (self.earlyTap && fabs(time - self.earlyTap.doubleValue) <= 0.22) {
        [self hitWithOffset:self.earlyTap.doubleValue - time];
        self.earlyTap = nil;
    } else {
        [self.beats addObject:@(time)];
    }
}
- (void)tapAtTime:(double)time {
    if (!self.active) return;
    [self advanceToTime:time];
    for (NSUInteger i = 0; i < self.beats.count; i++) {
        double offset = time - self.beats[i].doubleValue;
        if (fabs(offset) <= 0.22) {
            [self hitWithOffset:offset];
            [self.beats removeObjectAtIndex:i];
            return;
        }
    }
    if (!self.earlyTap) self.earlyTap = @(time);
}
@end

@implementation LBPlaygroundView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
}
- (void)keyDown:(NSEvent *)event {
    if ([event.charactersIgnoringModifiers isEqualToString:@" "] && self.game.active) {
        if (!event.isARepeat && self.onTap) self.onTap();
        return;
    }
    [super keyDown:event];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(bounds);
    CGFloat x = NSMidX(bounds) - 180;
    NSBezierPath *lid = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, 110, 360, 210)
                                                      xRadius:18 yRadius:18];
    NSGradient *metal = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0.42 alpha:1]
                                                    endingColor:[NSColor colorWithWhite:0.15 alpha:1]];
    [metal drawInBezierPath:lid angle:90];
    [[NSColor colorWithWhite:0.6 alpha:1] setStroke];
    lid.lineWidth = 2;
    [lid stroke];
    NSBezierPath *base = [NSBezierPath bezierPath];
    [base moveToPoint:NSMakePoint(x - 30, 106)];
    [base lineToPoint:NSMakePoint(x + 390, 106)];
    [base lineToPoint:NSMakePoint(x + 375, 91)];
    [base lineToPoint:NSMakePoint(x - 15, 91)];
    [base closePath];
    [[NSColor colorWithWhite:0.5 alpha:1] setFill];
    [base fill];
    NSRect logoRect = NSMakeRect(NSMidX(bounds) - 26, 188, 52, 56);
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:1 alpha:self.controlsLight ? self.glow * 0.7 : 0];
    shadow.shadowBlurRadius = 8 + self.glow * 25;
    shadow.shadowOffset = NSZeroSize;
    [shadow set];
    NSImage *logo = [[NSImage imageWithSystemSymbolName:@"apple.logo" accessibilityDescription:@"Logo preview"]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.whiteColor]];
    [logo drawInRect:logoRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
             fraction:self.controlsLight ? 0.15 + self.glow * 0.85 : 0.4];
    [NSGraphicsContext restoreGraphicsState];
    if (self.game.active) {
        double pulse = exp(-fmax(0, self.beatAge) / 0.25);
        NSRect ring = NSInsetRect(logoRect, -14 - pulse * 10, -10 - pulse * 10);
        NSBezierPath *path = [NSBezierPath bezierPathWithOvalInRect:ring];
        [[NSColor controlAccentColor] setStroke];
        path.lineWidth = 2 + pulse * 3;
        [path stroke];
    }
    NSMutableParagraphStyle *center = [NSMutableParagraphStyle new];
    center.alignment = NSTextAlignmentCenter;
    NSDictionary *text = @{NSFontAttributeName: [NSFont systemFontOfSize:13],
                           NSForegroundColorAttributeName: NSColor.labelColor,
                           NSParagraphStyleAttributeName: center};
    NSString *caption = self.caption ?: @"Logo preview";
    [caption drawInRect:NSMakeRect(0, 342, bounds.size.width, 22) withAttributes:text];
    NSString *score = [NSString stringWithFormat:@"Score %ld    Combo %ld    Hits %ld    Misses %ld",
                      (long)self.game.score, (long)self.game.combo, (long)self.game.hits, (long)self.game.misses];
    [score drawInRect:NSMakeRect(0, 58, bounds.size.width, 22) withAttributes:text];
    [self.game.feedback drawInRect:NSMakeRect(0, 30, bounds.size.width, 22) withAttributes:text];
    for (int i = 0; i < 9; i++) {
        double height = 3 + 12 * self.audioStrength * (0.5 + 0.5 * sin(self.time * 6 + i));
        [[NSColor controlAccentColor] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMidX(bounds) - 45 + i * 10, 8, 5, height)
                                          xRadius:2 yRadius:2] fill];
    }
}
@end

static NSData *RenderPreview(LBPlaygroundView *view) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:560 pixelsHigh:374 bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    if (!bitmap) return nil;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
    [view drawRect:view.bounds];
    [NSGraphicsContext restoreGraphicsState];
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

BOOL LBRunPlayfulTests(NSString *previewPath) {
#define CHECK(condition) do { if (!(condition)) { NSLog(@"Playful test failed at line %d: %s", __LINE__, #condition); return NO; } } while (0)
    LBAnimator *animator = [LBAnimator new];
    [animator resetAtTime:0];
    [animator updateLevel:0 atTime:2];
    CHECK(!animator.controlsLight && animator.output == 0);
    animator.mode = LBAnimationBreathing;
    [animator updateLevel:0 atTime:2.05];
    CHECK(animator.controlsLight && animator.output > 0);
    animator.mode = LBAnimationVolume;
    animator.idleBreathing = YES;
    [animator updateLevel:0 atTime:2.1];
    CHECK(animator.controlsLight);
    animator.idleBreathing = NO;
    [animator resetAtTime:0];
    animator.mode = LBAnimationDJ;
    [animator updateLevel:0.1 atTime:0.05];
    CHECK(animator.detectedBeat);
    double previous = animator.output;
    [animator updateLevel:0.8 atTime:0.1];
    CHECK(!animator.detectedBeat && animator.output - previous <= 0.080001);
    [animator updateLevel:0.01 atTime:0.75];
    [animator updateLevel:0.9 atTime:0.8];
    CHECK(animator.detectedBeat);
    for (NSInteger mood = LBMoodChill; mood <= LBMoodHeartbeat; mood++) {
        animator.mood = mood;
        [animator resetAtTime:0];
        for (int i = 0; i < 100; i++) {
            [animator updateLevel:i % 3 == 0 ? 0.9 : 0.03 atTime:1 + i * 0.05];
            CHECK(animator.requestedNits >= 12.5 && animator.requestedNits <=
                  (mood == LBMoodChill ? 180 : mood == LBMoodHeartbeat ? 240 : 300));
        }
    }
    LBAnimator *volume = [LBAnimator new], *dj = [LBAnimator new];
    dj.mode = LBAnimationDJ;
    for (int i = 1; i <= 20; i++) {
        [volume updateLevel:0.1 atTime:i * 0.05];
        [dj updateLevel:0.1 atTime:i * 0.05];
    }
    CHECK(fabs(volume.output - dj.output) > 0.05);
    NSError *error = nil;
    NSArray<LBMorseStep *> *steps = EncodeMorse(@"E E", &error);
    CHECK(steps.count == 3 && steps[0].units == 1 && steps[1].units == 7 &&
          !steps[1].lit && steps[2].lit);
    steps = EncodeMorse(@"A", &error);
    CHECK(steps.count == 3 && steps[0].units == 1 && steps[1].units == 1 && steps[2].units == 3);
    CHECK(!EncodeMorse(@"?", &error) && error);
    CHECK(!EncodeMorse(@"   ", &error));
    CHECK(!EncodeMorse(@"ABCDEFGHIJKLMNOPQRSTUVWXYZ", &error));
    [animator resetAtTime:10];
    CHECK([animator sendMorse:@"E" atTime:10 error:&error]);
    [animator updateLevel:0 atTime:10.05];
    CHECK(animator.morseActive && animator.controlsLight && animator.morseRemaining > 0);
    CHECK(![animator sendMorse:@"!" atTime:10.1 error:&error] && animator.morseActive);
    [animator updateLevel:0 atTime:10.7];
    CHECK(!animator.morseActive && !animator.controlsLight);
    [animator sendMorse:@"SOS" atTime:11 error:&error];
    [animator cancelMorse];
    CHECK(!animator.morseActive && animator.morseRemaining == 0);
    LBRhythmGame *game = [LBRhythmGame new];
    [game start];
    [game addBeatAtTime:1];
    [game tapAtTime:1.04];
    CHECK(game.hits == 1 && game.score == 105 && game.combo == 1);
    [game tapAtTime:2];
    [game addBeatAtTime:2.1];
    CHECK(game.hits == 2 && game.score == 175);
    [game addBeatAtTime:3];
    [game advanceToTime:3.3];
    CHECK(game.misses == 1 && game.combo == 0);
    [game tapAtTime:4];
    [game advanceToTime:4.3];
    CHECK(game.misses == 2);
    [game stop];
    [game tapAtTime:5];
    [game addBeatAtTime:5];
    CHECK(game.hits == 2 && !game.active);
    [game start];
    CHECK(game.score == 0 && game.hits == 0 && game.misses == 0);
    CHECK(LBWaveformIcon(0.5, 1).template);
    LBPlaygroundView *view = [[LBPlaygroundView alloc] initWithFrame:NSMakeRect(0, 0, 560, 374)];
    view.game = game;
    __block NSInteger taps = 0;
    view.onTap = ^{ taps++; };
    NSEvent *space = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
        timestamp:1 windowNumber:0 context:nil characters:@" " charactersIgnoringModifiers:@" "
        isARepeat:NO keyCode:49];
    NSEvent *repeat = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
        timestamp:1 windowNumber:0 context:nil characters:@" " charactersIgnoringModifiers:@" "
        isARepeat:YES keyCode:49];
    [view keyDown:space];
    [view keyDown:repeat];
    CHECK(taps == 1);
    view.controlsLight = YES;
    view.glow = 0.15;
    view.audioStrength = 0.65;
    view.beatAge = 0.15;
    view.time = 1;
    view.caption = @"Party / DJ pulses - brightness preview";
    NSData *dim = RenderPreview(view);
    view.glow = 0.8;
    NSData *bright = RenderPreview(view);
    CHECK(dim && bright && ![dim isEqualToData:bright]);
    if (previewPath) CHECK([bright writeToFile:previewPath atomically:YES]);
    [game stop];
    view.onTap = nil;
#undef CHECK
    return YES;
}
