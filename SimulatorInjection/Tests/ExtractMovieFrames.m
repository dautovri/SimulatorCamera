// Export the original asset as an ordinary player displays it. No corrective rotation.
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 3) return 2;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(argv[1])] options:nil];
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    for (int i = 0; i < 3; i++) {
        NSError *error = nil;
        CGImageRef image = [generator copyCGImageAtTime:CMTimeMake(3 + 7 * i, 10) actualTime:NULL error:&error];
        if (!image) { NSLog(@"%@", error); return 1; }
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s-%d.png", argv[2], i + 1]];
        CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
        CGImageDestinationAddImage(destination, image, NULL);
        BOOL saved = CGImageDestinationFinalize(destination);
        CFRelease(destination); CGImageRelease(image);
        if (!saved) return 1;
    }
    return 0;
} }
