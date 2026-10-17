// Optional hardware-boundary fixture. Selects devices only for this process;
// never changes the host's default input/output. Requires an existing loopback device.
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <math.h>

@interface HostMicFeed : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@property AVAudioPlayerNode *player;
@property double sum;
@property NSUInteger count;
@property BOOL ready;
@end
@implementation HostMicFeed
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithStreamDescription:CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample))];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)CMSampleBufferGetNumSamples(sample)];
    buffer.frameLength = buffer.frameCapacity;
    if (CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, 0, buffer.frameLength, buffer.mutableAudioBufferList) != noErr) return;
    if (buffer.floatChannelData) {
        for (AVAudioFrameCount i = 0; i < buffer.frameLength; i++) { double v = buffer.floatChannelData[0][i * buffer.stride]; self.sum += v * v; self.count++; }
    }
    [self.player scheduleBuffer:buffer completionHandler:nil];
    if (!self.ready) { self.ready = YES; fprintf(stderr, "READY microphone samples\n"); }
}
@end

static AudioDeviceID findDevice(NSString *wanted) {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size);
    AudioDeviceID *devices = malloc(size);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices);
    AudioDeviceID result = kAudioObjectUnknown;
    for (UInt32 i = 0; i < size / sizeof(AudioDeviceID); i++) {
        AudioObjectPropertyAddress nameAddress = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        CFStringRef name = NULL; UInt32 nameSize = sizeof(name);
        AudioObjectGetPropertyData(devices[i], &nameAddress, 0, NULL, &nameSize, &name);
        if ([(__bridge NSString *)name isEqual:wanted]) result = devices[i];
        if (name) CFRelease(name);
    }
    free(devices); return result;
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: HostAudioFeed <output-device-name> <seconds> [input-device-name]\n"); return 2; }
    NSString *outputName = @(argv[1]); double seconds = atof(argv[2]);
    dispatch_source_t parentWatch = nil;
    if (getenv("SIMCAM_STOP_ON_STDIN_EOF")) {
        parentWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
        dispatch_source_set_event_handler(parentWatch, ^{ char byte; if (read(STDIN_FILENO, &byte, 1) == 0) exit(0); });
        dispatch_resume(parentWatch);
    }
    AudioDeviceID output = findDevice(outputName);
    if (!output) { fprintf(stderr, "No output device %s\n", argv[1]); return 2; }
    AVAudioEngine *engine = [AVAudioEngine new];
    AudioUnit outputUnit = engine.outputNode.audioUnit;
    OSStatus status = AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &output, sizeof(output));
    if (status) { fprintf(stderr, "Output selection failed %d\n", (int)status); return 2; }
    AVAudioPlayerNode *player = nil;
    AVCaptureSession *capture = nil;
    HostMicFeed *feed = nil;
    if (argc > 3) {
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) {
            fprintf(stderr, "BLOCKED: host microphone permission is not authorized for HostAudioFeed (no permission bypass attempted)\n"); return 3;
        }
        AVCaptureDevice *mic = nil;
        for (AVCaptureDevice *device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio])
            if ([device.localizedName isEqual:@(argv[3])]) mic = device;
        if (!mic) { fprintf(stderr, "No microphone named %s\n", argv[3]); return 2; }
        capture = [AVCaptureSession new];
        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:mic error:&error];
        if (!input || ![capture canAddInput:input]) { fprintf(stderr, "%s\n", error.description.UTF8String); return 2; }
        [capture addInput:input];
        AVCaptureAudioDataOutput *audio = [AVCaptureAudioDataOutput new];
        audio.audioSettings = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @48000, AVNumberOfChannelsKey: @1, AVLinearPCMBitDepthKey: @32, AVLinearPCMIsFloatKey: @YES, AVLinearPCMIsNonInterleaved: @NO};
        player = [AVAudioPlayerNode new]; [engine attachNode:player];
        [engine connect:player to:engine.mainMixerNode format:[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1]];
        feed = [HostMicFeed new]; feed.player = player;
        [audio setSampleBufferDelegate:feed queue:dispatch_queue_create("probe.microphone", DISPATCH_QUEUE_SERIAL)];
        [capture addOutput:audio];
        fprintf(stderr, "LIVE input=%s -> output=%s\n", argv[3], argv[1]);
    } else {
        player = [AVAudioPlayerNode new]; [engine attachNode:player];
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        [engine connect:player to:engine.mainMixerNode format:format];
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:48000];
        buffer.frameLength = 48000;
        for (NSUInteger channel = 0; channel < 2; channel++)
            for (NSUInteger frame = 0; frame < 48000; frame++) buffer.floatChannelData[channel][frame] = 0.2 * sin(2 * M_PI * 440 * frame / 48000.0);
        [player scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
        fprintf(stderr, "GENERATED 440Hz tone -> output=%s\n", argv[1]);
    }
    NSError *error = nil;
    __block double renderedSum = 0;
    __block NSUInteger renderedCount = 0;
    [engine.mainMixerNode installTapOnBus:0 bufferSize:1024 format:nil block:^(AVAudioPCMBuffer *buffer, AVAudioTime *time) {
        for (AVAudioFrameCount i = 0; i < buffer.frameLength; i++) {
            double value = buffer.floatChannelData[0][i * buffer.stride];
            renderedSum += value * value; renderedCount++;
        }
    }];
    if (![engine startAndReturnError:&error]) { fprintf(stderr, "%s\n", error.description.UTF8String); return 1; }
    [player play];
    [capture startRunning];
    if (seconds > 0) [NSThread sleepForTimeInterval:seconds];
    else while (YES) pause(); // Managed bridge closes stdin or sends SIGTERM to release hardware.
    [engine stop];
    [engine.mainMixerNode removeTapOnBus:0];
    [capture stopRunning];
    if (feed) fprintf(stderr, "LIVE microphone samples=%lu rms=%g\n", (unsigned long)feed.count, feed.count ? sqrt(feed.sum / feed.count) : 0);
    fprintf(stderr, "RENDERED to selected output samples=%lu rms=%g\n", (unsigned long)renderedCount, renderedCount ? sqrt(renderedSum / renderedCount) : 0);
    return 0;
} }
