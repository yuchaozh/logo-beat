#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, LBAnimationMode) {
    LBAnimationVolume,
    LBAnimationDJ,
    LBAnimationBreathing,
    LBAnimationAutomatic
};

typedef NS_ENUM(NSInteger, LBMood) {
    LBMoodChill,
    LBMoodParty,
    LBMoodHeartbeat
};

double LBNormalizedAudio(double level, double reference);
NSString *LBModeName(LBAnimationMode mode);
NSString *LBMoodName(LBMood mood);
NSImage *LBWaveformIcon(double level, double time);

@interface LBAnimator : NSObject
@property LBAnimationMode mode;
@property LBMood mood;
@property BOOL idleBreathing;
@property(readonly) double output;
@property(readonly) double audioStrength;
@property(readonly) double requestedNits;
@property(readonly) double lastBeat;
@property(readonly) BOOL detectedBeat;
@property(readonly) BOOL controlsLight;
@property(readonly) BOOL breathing;
@property(readonly) BOOL morseActive;
@property(readonly) double morseRemaining;
- (void)resetAtTime:(double)time;
- (void)updateLevel:(double)level atTime:(double)time;
- (BOOL)sendMorse:(NSString *)text atTime:(double)time error:(NSError **)error;
- (void)cancelMorse;
@end

@interface LBRhythmGame : NSObject
@property(readonly) BOOL active;
@property(readonly) NSInteger score;
@property(readonly) NSInteger combo;
@property(readonly) NSInteger hits;
@property(readonly) NSInteger misses;
@property(readonly) NSString *feedback;
- (void)start;
- (void)stop;
- (void)advanceToTime:(double)time;
- (void)addBeatAtTime:(double)time;
- (void)tapAtTime:(double)time;
@end

@interface LBPlaygroundView : NSView
@property double glow;
@property double audioStrength;
@property double beatAge;
@property double time;
@property BOOL controlsLight;
@property NSString *caption;
@property LBRhythmGame *game;
@property(copy) void (^onTap)(void);
@end

BOOL LBRunPlayfulTests(NSString *previewPath);
