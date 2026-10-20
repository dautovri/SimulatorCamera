#import "SCMovieRecorder.h"
#import "SCVideoGeometry.h"
#import <math.h>

@interface SCMovieRecorder ()
@property (atomic, readwrite, getter=isRecording) BOOL recording;
@property (nonatomic, readwrite) BOOL finished;
@end

@implementation SCMovieRecorder {
    AVCaptureMovieFileOutput *_output; // Retained only until the terminal callback is enqueued.
    NSURL *_url;
    id<AVCaptureFileOutputRecordingDelegate> _delegate;
    NSArray<AVCaptureConnection *> *_connections;
    BOOL _needsAudio, _started, _stopping, _hasVideo, _hasAudio;
    CGFloat _rotation;
    CGFloat _sourcePortraitRotation;
    BOOL _mirrored;
    dispatch_queue_t _queue;
    AVAudioEngine *_engine;
    AVAssetWriter *_writer;
    AVAssetWriterInput *_video, *_audio;
    AVAssetWriterInputPixelBufferAdaptor *_adaptor;
    NSMutableArray *_pendingAudio;
    CMTime _origin, _lastVideo, _lastAudio, _lastAudioEnd;
    double _sampleRate;
    size_t _width, _height;
    id _interruptionObserver;
    id _engineObserver;
    BOOL _tapInstalled;
#if SIMCAM_RECORDING_TESTS
    dispatch_source_t _testAudioTimer;
#endif
}

static NSError *SCMovieError(NSString *message) {
    return [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorUnknown
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void SCRecordingLog(NSString *message) {
    if (getenv("SIMCAM_RECORDING_LOG")) NSLog(@"[SimulatorCamera] movie %@", message);
}

- (instancetype)initWithOutput:(AVCaptureMovieFileOutput *)output URL:(NSURL *)url
                     delegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate
                  connections:(NSArray<AVCaptureConnection *> *)connections audio:(BOOL)audio
                     rotation:(CGFloat)rotation mirrored:(BOOL)mirrored queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _output = output; _url = url; _delegate = delegate; _connections = connections;
        _needsAudio = audio; _rotation = rotation; _mirrored = mirrored; _queue = queue;
        _pendingAudio = [NSMutableArray array];
        _lastVideo = _lastAudio = _lastAudioEnd = kCMTimeInvalid;
    }
    return self;
}

- (void)start {
    SCRecordingLog(@"starting");
    self.recording = YES;
    _origin = CMClockGetTime(CMClockGetHostTimeClock());
    if (!_url.isFileURL || [[NSFileManager defaultManager] fileExistsAtPath:_url.path]) {
        [self fail:SCMovieError(@"Recording requires a new local file URL")]; return;
    }
    __weak SCMovieRecorder *weakSelf = self;
    dispatch_queue_t queue = _queue;
    _interruptionObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        if ([note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan)
            dispatch_async(queue, ^{ [weakSelf stop]; });
    }];
    if (_needsAudio) {
        if (AVAudioSession.sharedInstance.recordPermission != AVAudioSessionRecordPermissionGranted) {
            [self fail:SCMovieError(@"Microphone permission has not been granted")]; return;
        }
#if SIMCAM_RECORDING_TESTS
        if (getenv("SC_TEST_TONE")) {
            // Test-build-only hardware boundary. Uses the production PCM encoder/muxer.
            _sampleRate = 48000;
            _testAudioTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
            __block uint64_t frame = 0;
            CMTime origin = _origin;
            dispatch_source_set_timer(_testAudioTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 20 * NSEC_PER_MSEC, NSEC_PER_MSEC);
            dispatch_source_set_event_handler(_testAudioTimer, ^{
                // A microphone clock keeps sampling when a dispatch timer coalesces.
                // Catch up samples rather than shortening audio when the encoder queue is busy.
                double elapsed = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), origin));
                uint64_t target = (uint64_t)(elapsed * 48000);
                if (target <= frame) return;
                NSUInteger count = (NSUInteger)(target - frame);
                CMTime pts = CMTimeAdd(origin, CMTimeMake(frame, 48000));
                NSMutableData *data = [NSMutableData dataWithLength:count * sizeof(float)];
                float *samples = data.mutableBytes;
                for (NSUInteger i = 0; i < count; i++, frame++) samples[i] = 0.2 * sin(2 * M_PI * 440 * frame / 48000.0);
                [weakSelf appendPCM:data time:pts];
            });
            dispatch_resume(_testAudioTimer);
        } else {
#endif
        // The caller owns AVAudioSession category/activation. Do not restore or replace its lease.
        _engine = [AVAudioEngine new];
        SCRecordingLog(@"obtaining microphone input node");
        AVAudioInputNode *input = _engine.inputNode;
        AVAudioFormat *format = [input outputFormatForBus:0];
        SCRecordingLog([NSString stringWithFormat:@"microphone format %@", format]);
        _sampleRate = format.sampleRate;
        if (!format.channelCount || _sampleRate <= 0 || format.commonFormat != AVAudioPCMFormatFloat32) {
            [self fail:SCMovieError(@"Microphone has no usable float PCM input format")]; return;
        }
        _engineObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVAudioEngineConfigurationChangeNotification object:_engine queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(queue, ^{ [weakSelf fail:SCMovieError(@"Microphone route changed during recording")]; });
        }];
        [input installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
            SCMovieRecorder *recorder = weakSelf;
            if (!recorder || !when.hostTimeValid || !buffer.frameLength) return;
            // Copy the microphone channel before the engine recycles its buffer.
            NSMutableData *pcm = [NSMutableData dataWithLength:buffer.frameLength * sizeof(float)];
            float *dst = pcm.mutableBytes;
            const float *src = buffer.floatChannelData[0];
            for (AVAudioFrameCount i = 0; i < buffer.frameLength; i++) dst[i] = src[i * buffer.stride];
            CMTime pts = CMClockMakeHostTimeFromSystemUnits(when.hostTime);
            dispatch_async(queue, ^{ [recorder appendPCM:pcm time:pts]; });
        }];
        _tapInstalled = YES;
        NSError *error = nil;
        SCRecordingLog(@"starting audio engine");
        if (![_engine startAndReturnError:&error]) { [self fail:error ?: SCMovieError(@"Microphone failed to start")]; return; }
        SCRecordingLog(@"audio engine running");
#if SIMCAM_RECORDING_TESTS
        }
#endif
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), _queue, ^{
        SCMovieRecorder *recorder = weakSelf;
        if (recorder && !recorder->_started && !recorder->_stopping && !recorder.finished)
            [recorder fail:SCMovieError(@"Timed out waiting for video and microphone samples")];
    });
}

- (BOOL)prepareWriter:(CVPixelBufferRef)pixels {
    NSError *error = nil;
    _writer = [[AVAssetWriter alloc] initWithURL:_url fileType:AVFileTypeQuickTimeMovie error:&error];
    if (!_writer) { [self fail:error]; return NO; }
    _width = CVPixelBufferGetWidth(pixels); _height = CVPixelBufferGetHeight(pixels);
    _video = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @(_width), AVVideoHeightKey: @(_height)}];
    _video.expectsMediaDataInRealTime = YES;
    _sourcePortraitRotation = SCFramePortraitRotation(pixels);
    _video.transform = SCVideoDisplayTransform(CGSizeMake(_width, _height), _rotation, _mirrored, _sourcePortraitRotation);
    _adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_video sourcePixelBufferAttributes:nil];
    if (![_writer canAddInput:_video]) { [self fail:SCMovieError(@"Video encoder unavailable")]; return NO; }
    [_writer addInput:_video];
    if (_needsAudio) {
        _audio = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:@{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @(_sampleRate), AVNumberOfChannelsKey: @1, AVEncoderBitRateKey: @96000}];
        _audio.expectsMediaDataInRealTime = YES;
        if (![_writer canAddInput:_audio]) { [self fail:SCMovieError(@"Audio encoder unavailable")]; return NO; }
        [_writer addInput:_audio];
    }
    if (![_writer startWriting]) { [self fail:_writer.error]; return NO; }
    [_writer startSessionAtSourceTime:_origin];
    NSArray *pending = [_pendingAudio copy]; [_pendingAudio removeAllObjects];
    for (NSArray *entry in pending) [self appendPCM:entry[0] time:[entry[1] CMTimeValue]];
    return !self.finished;
}

- (void)appendVideo:(CVPixelBufferRef)pixels time:(CMTime)time {
    if (_stopping || self.finished || !self.recording) return;
    if (_started && _needsAudio && CMTIME_IS_VALID(_lastAudioEnd) && CMTimeGetSeconds(CMTimeSubtract(time, _lastAudioEnd)) > 1) {
        [self fail:SCMovieError(@"Microphone stopped delivering samples")]; return;
    }
    if (!_writer && ![self prepareWriter:pixels]) return;
    if (_width != CVPixelBufferGetWidth(pixels) || _height != CVPixelBufferGetHeight(pixels)) {
        [self fail:SCMovieError(@"Video dimensions changed during recording")]; return;
    }
    if (_sourcePortraitRotation != SCFramePortraitRotation(pixels)) {
        [self fail:SCMovieError(@"Video source orientation changed during recording")]; return;
    }
    if (CMTIME_IS_VALID(_lastVideo) && CMTimeCompare(time, _lastVideo) <= 0) return;
    if (!_video.readyForMoreMediaData) return;
    if (![_adaptor appendPixelBuffer:pixels withPresentationTime:time]) { [self fail:_writer.error]; return; }
    _lastVideo = time; _hasVideo = YES;
    [self notifyStartedIfReady];
}

- (void)appendPCM:(NSData *)pcm time:(CMTime)time {
#if SIMCAM_RECORDING_TESTS
    if (getenv("SC_TEST_NO_AUDIO")) return;
#endif
    if (_stopping || self.finished || CMTimeCompare(time, _origin) < 0) return;
    if (!_writer) {
        if (_pendingAudio.count < 100) [_pendingAudio addObject:@[pcm, [NSValue valueWithCMTime:time]]];
        return;
    }
    if (CMTIME_IS_VALID(_lastAudio) && CMTimeCompare(time, _lastAudio) <= 0) return;
    if (!_audio.readyForMoreMediaData) { [self fail:SCMovieError(@"Audio encoder cannot keep up with microphone samples")]; return; }
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = _sampleRate; asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame = sizeof(float); asbd.mFramesPerPacket = 1;
    asbd.mChannelsPerFrame = 1; asbd.mBitsPerChannel = 32;
    CMAudioFormatDescriptionRef format = NULL;
    CMBlockBufferRef block = NULL; CMSampleBufferRef sample = NULL;
    OSStatus status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &format);
    if (!status) status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, pcm.length, kCFAllocatorDefault, NULL, 0, pcm.length, 0, &block);
    if (!status) status = CMBlockBufferReplaceDataBytes(pcm.bytes, block, 0, pcm.length);
    if (!status) status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, block, format, pcm.length / sizeof(float), time, NULL, &sample);
    BOOL appended = !status && [_audio appendSampleBuffer:sample];
    if (sample) CFRelease(sample); if (block) CFRelease(block); if (format) CFRelease(format);
    if (!appended) { [self fail:_writer.error ?: SCMovieError(@"Could not encode microphone PCM")]; return; }
    _lastAudio = time;
    _lastAudioEnd = CMTimeAdd(time, CMTimeMake(pcm.length / sizeof(float), (int32_t)_sampleRate));
    _hasAudio = YES;
    [self notifyStartedIfReady];
}

- (void)notifyStartedIfReady {
    if (_started || !_hasVideo || (_needsAudio && !_hasAudio)) return;
    _started = YES;
    SCRecordingLog(@"didStart");
    AVCaptureMovieFileOutput *output = _output;
    id<AVCaptureFileOutputRecordingDelegate> delegate = _delegate;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([delegate respondsToSelector:@selector(captureOutput:didStartRecordingToOutputFileAtURL:fromConnections:)])
            [delegate captureOutput:output didStartRecordingToOutputFileAtURL:self->_url fromConnections:self->_connections];
    });
}

- (void)stopAudio {
    SCRecordingLog(@"stopping audio");
#if SIMCAM_RECORDING_TESTS
    if (_testAudioTimer) { dispatch_source_cancel(_testAudioTimer); _testAudioTimer = nil; }
#endif
    if (_interruptionObserver) [NSNotificationCenter.defaultCenter removeObserver:_interruptionObserver];
    if (_engineObserver) [NSNotificationCenter.defaultCenter removeObserver:_engineObserver];
    _interruptionObserver = _engineObserver = nil;
    if (_engine) { [_engine stop]; if (_tapInstalled) [_engine.inputNode removeTapOnBus:0]; _tapInstalled = NO; _engine = nil; }
    SCRecordingLog(@"audio stopped");
    [_pendingAudio removeAllObjects];
}

- (void)stop {
    SCRecordingLog(@"stop requested");
    if (_stopping || self.finished) return;
    _stopping = YES; self.recording = NO;
    [self stopAudio];
    if (!_started) { [self fail:SCMovieError(@"Recording stopped before audio/video startup completed")]; return; }
    [_video markAsFinished]; [_audio markAsFinished];
    [_writer finishWritingWithCompletionHandler:^{
        dispatch_async(self->_queue, ^{
            [self complete:self->_writer.status == AVAssetWriterStatusCompleted ? nil : self->_writer.error ?: SCMovieError(@"Movie finalization failed")];
        });
    }];
}

- (void)fail:(NSError *)error {
    if (self.finished || (_stopping && _writer.status == AVAssetWriterStatusCompleted)) return;
    _stopping = YES; self.recording = NO;
    [self stopAudio];
    if (_writer.status == AVAssetWriterStatusWriting) [_writer cancelWriting];
    [self complete:error ?: SCMovieError(@"Movie recording failed")];
}

- (void)complete:(NSError *)error {
    if (self.finished) return;
    self.finished = YES; self.recording = NO;
    SCRecordingLog([NSString stringWithFormat:@"didFinish error=%@", error]);
    AVCaptureMovieFileOutput *output = _output;
    id<AVCaptureFileOutputRecordingDelegate> delegate = _delegate;
    _delegate = nil;
    _output = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate captureOutput:output didFinishRecordingToOutputFileAtURL:self->_url fromConnections:self->_connections error:error];
    });
}
@end
