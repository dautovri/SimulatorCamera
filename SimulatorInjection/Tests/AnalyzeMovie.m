// Decode the actual finalized file; track metadata alone is not recording proof.
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <math.h>
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2) return 2;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(argv[1])] options:nil];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"duration"] = @(CMTimeGetSeconds(asset.duration));
    BOOL pass = YES;
    for (AVMediaType type in @[AVMediaTypeVideo, AVMediaTypeAudio]) {
        AVAssetTrack *track = [asset tracksWithMediaType:type].firstObject;
        if (!track) { result[type] = @{@"error": @"missing track"}; pass = NO; continue; }
        NSError *error = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        NSDictionary *settings = [type isEqual:AVMediaTypeVideo]
            ? @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}
            : @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: @32,
                AVLinearPCMIsFloatKey: @YES, AVLinearPCMIsNonInterleaved: @NO};
        AVAssetReaderTrackOutput *out = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
        [reader addOutput:out];
        [reader startReading];
        NSUInteger count = 0, changes = 0, audioValues = 0, crossings = 0;
        double previousAudio = 0, sampleRate = 0;
        double first = -1, last = -1, end = -1, sum = 0, peak = 0;
        BOOL monotonic = YES;
        uint64_t previousHash = 0;
        CMSampleBufferRef sample;
        while ((sample = [out copyNextSampleBuffer])) {
            double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
            if (!count) first = pts;
            if (count && pts <= last) monotonic = NO;
            last = pts;
            double duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample));
            end = pts + (isfinite(duration) ? duration : 0);
            count++;
            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
            if (pb) {
                CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
                const uint8_t *bytes = CVPixelBufferGetBaseAddress(pb);
                size_t length = CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb);
                uint64_t hash = 1469598103934665603ULL;
                for (size_t i = 0; i < length; i += 97) hash = (hash ^ bytes[i]) * 1099511628211ULL;
                if (count > 1 && hash != previousHash) changes++;
                previousHash = hash;
                CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            } else {
                const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample));
                sampleRate = asbd->mSampleRate;
                CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
                size_t length = CMBlockBufferGetDataLength(block);
                float *values = malloc(length);
                if (CMBlockBufferCopyDataBytes(block, 0, length, values) == noErr) {
                    for (size_t i = 0; i < length / sizeof(float); i++) {
                        double value = values[i]; sum += value * value; peak = fmax(peak, fabs(value));
                        if (audioValues && previousAudio <= 0 && value > 0) crossings++;
                        previousAudio = value; audioValues++;
                    }
                }
                free(values);
            }
            CFRelease(sample);
        }
        NSMutableDictionary *metrics = [@{@"samples": @(count), @"firstPTS": @(first), @"lastPTS": @(last), @"endPTS": @(end), @"monotonic": @(monotonic), @"readerStatus": @(reader.status)} mutableCopy];
        if ([type isEqual:AVMediaTypeVideo]) {
            metrics[@"changedFrames"] = @(changes);
            CGAffineTransform t = track.preferredTransform;
            metrics[@"transform"] = @[@(t.a), @(t.b), @(t.c), @(t.d), @(t.tx), @(t.ty)];
            metrics[@"width"] = @(track.naturalSize.width); metrics[@"height"] = @(track.naturalSize.height);
            pass &= changes > 0;
        } else {
            double rms = audioValues ? sqrt(sum / audioValues) : 0;
            metrics[@"rms"] = @(rms); metrics[@"peak"] = @(peak);
            metrics[@"positiveCrossingFrequency"] = @(audioValues ? crossings * sampleRate / audioValues : 0);
            pass &= rms > 0.00001;
        }
        if (reader.error) metrics[@"error"] = reader.error.description;
        result[type] = metrics;
        pass &= count > 1 && monotonic && reader.status == AVAssetReaderStatusCompleted;
    }
    result[@"pass"] = @(pass);
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    return pass ? 0 : 1;
} }
