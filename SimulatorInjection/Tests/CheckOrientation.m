#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>

static NSString *corners(CGImageRef image) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger i = 0; i < 4; i++) {
        NSColor *color = [[bitmap colorAtX:(NSInteger)(bitmap.pixelsWide * (i % 2 ? .8 : .2))
                                        y:(NSInteger)(bitmap.pixelsHigh * (i / 2 ? .8 : .2))] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        CGFloat r = color.redComponent, g = color.greenComponent, b = color.blueComponent;
        NSString *name = r > .6 && g > .6 && b < .3 ? @"Y" : r > .6 && g < .3 && b < .3 ? @"R" : g > .6 && r < .3 && b < .3 ? @"G" : b > .6 && r < .3 && g < .3 ? @"B" : @"?";
        [result appendString:name];
    }
    return result;
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 6) { fprintf(stderr, "usage: CheckOrientation movie angle mirrored preview.png extracted.png\n"); return 2; }
    int angle = atoi(argv[2]); BOOL mirrored = atoi(argv[3]);
    // Independently specified visual corners TL,TR,BL,BR. A portrait (90°)
    // connection must show the upright host image; other requests remain rotations.
    NSDictionary *expected = @{@0: @[@"GYRB", @"YGBR"], @90: @[@"RGBY", @"GRYB"],
                               @180: @[@"BRYG", @"RBGY"], @270: @[@"YBGR", @"BYRG"]};
    NSString *wanted = expected[@(angle)][mirrored ? 1 : 0];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(argv[1])] options:nil];
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES; // Normal player semantics; no corrective transform.
    NSError *error = nil;
    CGImageRef movie = [generator copyCGImageAtTime:CMTimeMake(1, 2) actualTime:NULL error:&error];
    if (!movie) { NSLog(@"decode failed %@", error); return 1; }
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[5])], CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(destination, movie, NULL); CGImageDestinationFinalize(destination); CFRelease(destination);
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[4])], NULL);
    CGImageRef preview = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
    NSString *movieCorners = corners(movie), *previewCorners = preview ? corners(preview) : @"missing";
    BOOL pass = [movieCorners isEqual:wanted] && [previewCorners isEqual:wanted];
    printf("%s angle=%d mirrored=%d expected=%s movie=%s preview=%s display=%zux%zu\n", pass ? "PASS" : "FAIL", angle, mirrored, wanted.UTF8String, movieCorners.UTF8String, previewCorners.UTF8String, CGImageGetWidth(movie), CGImageGetHeight(movie));
    CGImageRelease(movie); if (preview) CGImageRelease(preview); if (source) CFRelease(source);
    return pass ? 0 : 1;
} }
