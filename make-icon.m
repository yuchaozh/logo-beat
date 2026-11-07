#import <AppKit/AppKit.h>

static BOOL WriteIcon(NSString *path, NSInteger pixels) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    if (!bitmap) return NO;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
    NSAffineTransform *scale = [NSAffineTransform transform];
    [scale scaleBy:(double)pixels / 1024];
    [scale concat];
    NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(72, 72, 880, 880)
                                                             xRadius:190 yRadius:190];
    NSGradient *gradient = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithSRGBRed:0.12 green:0.48 blue:0.98 alpha:1]
                  endingColor:[NSColor colorWithSRGBRed:0.47 green:0.18 blue:0.86 alpha:1]];
    [gradient drawInBezierPath:background angle:-35];
    [[NSColor colorWithWhite:1 alpha:0.98] setFill];
    const double heights[] = {160, 300, 470, 360, 220};
    for (int i = 0; i < 5; i++) {
        double height = heights[i];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(262 + i * 108, 512 - height / 2, 68, height)
                                          xRadius:34 yRadius:34] fill];
    }
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return png && [png writeToFile:path atomically:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "Usage: make-icon <iconset-directory>\n");
            return 1;
        }
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                      attributes:nil error:&error]) {
            NSLog(@"Could not create iconset: %@", error);
            return 1;
        }
        for (NSNumber *size in @[@16, @32, @128, @256, @512]) {
            for (NSInteger density = 1; density <= 2; density++) {
                NSString *name = [NSString stringWithFormat:@"icon_%ldx%ld%@.png",
                                  size.integerValue, size.integerValue, density == 2 ? @"@2x" : @""];
                if (!WriteIcon([directory stringByAppendingPathComponent:name], size.integerValue * density)) {
                    NSLog(@"Could not write icon: %@", name);
                    return 1;
                }
            }
        }
    }
    return 0;
}
