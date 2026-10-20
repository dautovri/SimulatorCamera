#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// Public-API acceptance probe: no imports or calls into the injection library.
@interface Probe : UIResponder <UIApplicationDelegate, AVCaptureFileOutputRecordingDelegate>
@property (nonatomic, strong) UIWindow *window;
@property AVCaptureSession *session;
@property AVCaptureMovieFileOutput *output;
@property NSURL *url;
@property NSString *scenario;
@property NSUInteger iteration;
@property NSUInteger starts;
@property NSUInteger finishes;
@property NSUInteger failures;
@property AVCaptureVideoPreviewLayer *preview;
@property id runtimeErrorObserver;
@end

@implementation Probe
- (NSURL *)documents { return [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject; }
- (void)log:(NSString *)message { NSLog(@"PROBE %@", message); }
- (void)check:(BOOL)condition message:(NSString *)message {
    if (!condition) { self.failures++; [self log:[@"FAIL " stringByAppendingString:message]]; }
}
- (void)done {
    if (self.runtimeErrorObserver) [NSNotificationCenter.defaultCenter removeObserver:self.runtimeErrorObserver];
    NSDictionary *result = @{@"case": self.scenario, @"starts": @(self.starts), @"finishes": @(self.finishes), @"failures": @(self.failures), @"pass": @(self.failures == 0)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:[[self documents] URLByAppendingPathComponent:[self.scenario stringByAppendingString:@".json"]] atomically:YES];
    [self log:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
    exit(self.failures ? 1 : 0);
}
- (BOOL)is:(NSString *)name { return [self.scenario isEqual:name]; }
- (BOOL)expectsFailure { return [@[@"immediate", @"not-running", @"existing-file", @"missing-directory", @"no-video", @"no-audio", @"denied-audio"] containsObject:self.scenario]; }
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.scenario = getenv("PROBE_CASE") ? @(getenv("PROBE_CASE")) : @"success";
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new]; vc.view.backgroundColor = UIColor.darkGrayColor;
    self.window.rootViewController = vc; [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self check:NO message:@"callback watchdog expired"]; [self done]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self configure]; });
    return YES;
}
- (void)configure {
    @try {
        NSError *error = nil;
        AVCaptureDevice *camera = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionFront] ?: [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        AVCaptureDevice *mic = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        [self log:[NSString stringWithFormat:@"devices camera=%@ microphone=%@", camera, mic]];
        [self check:camera && mic message:@"native camera/microphone discovery"];
        if (!camera || !mic) { [self done]; return; }
        AVCaptureDeviceInput *video = [[AVCaptureDeviceInput alloc] initWithDevice:camera error:&error];
        AVCaptureDeviceInput *audio = [[AVCaptureDeviceInput alloc] initWithDevice:mic error:&error];
        if ([self is:@"denied-audio"]) {
            // AVFoundation rejects input creation before a recorder exists. Preserve that gate.
            [self check:video && !audio && error != nil message:@"native denied microphone input must fail"];
            [self check:[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusDenied message:@"permission decision remains truthful"];
            [self done]; return;
        }
        [self check:video && audio message:@"native input constructors"];
        if (!video || !audio) { [self done]; return; }
        AVAudioSession *as = AVAudioSession.sharedInstance;
        [self check:[as setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeVideoRecording options:AVAudioSessionCategoryOptionDefaultToSpeaker error:&error] message:@"audio category"];
        [self check:[as setActive:YES error:&error] message:@"audio activation"];
        self.session = [AVCaptureSession new]; self.output = [AVCaptureMovieFileOutput new];
        if ([self is:@"preview-lifecycle"]) {
            __weak Probe *weakSelf = self;
            self.runtimeErrorObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionRuntimeErrorNotification object:self.session queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                [weakSelf check:NO message:@"preview attachment must not emit a capture runtime error"];
            }];
            // Match SwiftUI: bind an empty session, then configure its inputs.
            self.preview = [AVCaptureVideoPreviewLayer new];
            self.preview.session = self.session;
            [self check:self.preview.session == self.session message:@"preview retains its session"];
            self.preview.frame = CGRectMake(20, 100, 320, 320);
            [self.window.rootViewController.view.layer addSublayer:self.preview];
        }
        [self.session beginConfiguration];
        self.session.automaticallyConfiguresApplicationAudioSession = NO;
        if ([self.session canSetSessionPreset:AVCaptureSessionPresetHigh]) self.session.sessionPreset = AVCaptureSessionPresetHigh;
        for (AVCaptureDeviceInput *input in @[video, audio]) {
            [self check:[self.session canAddInput:input] message:@"canAddInput"];
            [self.session addInput:input];
        }
        [self check:[self.session canAddOutput:self.output] message:@"canAddOutput"];
        [self.session addOutput:self.output]; [self.session commitConfiguration];
        [self check:[self.session.outputs containsObject:self.output] message:@"session owns configured output"];
        AVCaptureConnection *v = [self.output connectionWithMediaType:AVMediaTypeVideo];
        AVCaptureConnection *a = [self.output connectionWithMediaType:AVMediaTypeAudio];
        [self check:v && a && v != a message:@"distinct video/audio connections"];
        [self check:self.output.connections.count == 2 message:@"delegate connection list"];
        [self check:[self.output connectionWithMediaType:AVMediaTypeMetadata] == nil message:@"unsupported media connection absent"];
        if (getenv("PROBE_ORIENTATION_ANGLE")) {
            self.preview = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
            self.preview.frame = CGRectMake(20, 100, 320, 320);
            self.preview.videoGravity = AVLayerVideoGravityResizeAspect;
            [self.window.rootViewController.view.layer addSublayer:self.preview];
        }
        [self record];
    } @catch (NSException *e) { [self check:NO message:e.description]; [self done]; }
}
- (void)record {
    self.iteration++;
    self.url = [[self documents] URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%lu.mov", self.scenario, (unsigned long)self.iteration]];
    [[NSFileManager defaultManager] removeItemAtURL:self.url error:nil];
    if ([self is:@"missing-directory"]) self.url = [[[self documents] URLByAppendingPathComponent:NSUUID.UUID.UUIDString] URLByAppendingPathComponent:@"absent.mov"];
    if ([self is:@"existing-file"]) [@"do not overwrite" writeToURL:self.url atomically:YES encoding:NSUTF8StringEncoding error:nil];
    AVCaptureConnection *v = [self.output connectionWithMediaType:AVMediaTypeVideo];
    if (@available(iOS 17, *)) {
        CGFloat angle = self.iteration == 1 ? 90 : 0;
        if (getenv("PROBE_ORIENTATION_ANGLE")) angle = atof(getenv("PROBE_ORIENTATION_ANGLE"));
        [self check:[v isVideoRotationAngleSupported:angle] message:@"rotation supported"];
        v.videoRotationAngle = angle;
        self.preview.connection.videoRotationAngle = angle;
    }
    v.automaticallyAdjustsVideoMirroring = NO;
    v.videoMirrored = self.iteration == 1;
    if (getenv("PROBE_ORIENTATION_ANGLE")) {
        v.videoMirrored = getenv("PROBE_ORIENTATION_MIRROR") && atoi(getenv("PROBE_ORIENTATION_MIRROR"));
        self.preview.connection.automaticallyAdjustsVideoMirroring = NO;
        self.preview.connection.videoMirrored = v.videoMirrored;
    }
    if (![self is:@"not-running"]) [self.session startRunning];
    [self check:self.session.isRunning == ![self is:@"not-running"] message:@"session running state"];
    [self.output startRecordingToOutputFileURL:self.url recordingDelegate:self];
    if ([self is:@"immediate"]) { [self.output stopRecording]; [self.output stopRecording]; }
}
- (void)captureOutput:(AVCaptureFileOutput *)output didStartRecordingToOutputFileAtURL:(NSURL *)url fromConnections:(NSArray *)connections {
    self.starts++;
    [self log:[NSString stringWithFormat:@"didStart %@", url.lastPathComponent]];
    [self check:!self.expectsFailure message:@"failure case must not report didStart"];
    [self check:self.starts == self.iteration && self.finishes == self.iteration - 1 message:@"exactly one ordered start"];
    [self check:output == self.output && [url isEqual:self.url] && connections.count == 2 message:@"start delegate arguments"];
    [self check:self.output.isRecording message:@"isRecording at didStart"];
    if (self.preview) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        CGImageRef image = (__bridge CGImageRef)self.preview.contents;
        [self check:image != NULL message:@"preview has a rendered frame"];
        if (image) [UIImagePNGRepresentation([UIImage imageWithCGImage:image]) writeToURL:[[self documents] URLByAppendingPathComponent:[self.scenario stringByAppendingString:@"-preview.png"]] atomically:YES];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([self is:@"session-stop"]) [self.session stopRunning];
        else if ([self is:@"remove-output"]) [self.session removeOutput:self.output];
        else if ([self is:@"drop-session"]) self.session = nil;
        else if ([self is:@"remove-input"]) {
            for (AVCaptureDeviceInput *input in self.session.inputs)
                if ([input.device hasMediaType:AVMediaTypeVideo]) [self.session removeInput:input];
        }
        else if ([self is:@"interruption"]) [NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionInterruptionNotification object:AVAudioSession.sharedInstance userInfo:@{AVAudioSessionInterruptionTypeKey: @(AVAudioSessionInterruptionTypeBegan)}];
        else { [self.output stopRecording]; [self.output stopRecording]; }
    });
}
- (void)captureOutput:(AVCaptureFileOutput *)output didFinishRecordingToOutputFileAtURL:(NSURL *)url fromConnections:(NSArray *)connections error:(NSError *)error {
    self.finishes++;
    [self log:[NSString stringWithFormat:@"didFinish %@ error=%@", url.lastPathComponent, error]];
    [self check:self.finishes == self.iteration message:@"exactly one finish per start request"];
    [self check:output == self.output && [url isEqual:self.url] && connections.count == 2 message:@"finish delegate arguments"];
    [self check:!self.output.isRecording message:@"isRecording false at didFinish"];
    [self check:(error != nil) == self.expectsFailure message:@"expected terminal error semantics"];
    [self.session stopRunning];
    if (self.expectsFailure) {
        [self check:self.starts == 0 message:@"no spurious start on startup failure"];
        [self check:![error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] boolValue] message:@"failure must not claim saved success"];
        if ([self is:@"existing-file"]) [self check:[[NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil] isEqual:@"do not overwrite"] message:@"existing destination preserved"];
    } else {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        [self check:[asset tracksWithMediaType:AVMediaTypeVideo].count == 1 && [asset tracksWithMediaType:AVMediaTypeAudio].count == 1 message:@"finalized audiovisual file readable inside didFinish"];
        [self check:CMTimeGetSeconds(asset.duration) > 1 message:@"nontrivial movie duration"];
    }
    if ([self is:@"success"] && self.iteration == 1) { [self record]; return; }
    if ([self is:@"preview-lifecycle"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __weak AVCaptureConnection *releasedConnection;
            @autoreleasepool {
                releasedConnection = self.preview.connection;
                [self check:releasedConnection != nil message:@"preview exposes a connection"];
                self.preview.session = nil;
                [self.preview removeFromSuperlayer];
                self.preview = nil;
                [CATransaction flush];
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                [self check:releasedConnection == nil message:@"dismissed preview releases its connection without crashing or leaking"];
                [self done];
            });
        });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ [self done]; });
}
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(Probe.class)); } }
