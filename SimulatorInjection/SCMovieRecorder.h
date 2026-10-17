#import <AVFoundation/AVFoundation.h>

// All methods except the atomic recording getter run on the injection frame queue.
@interface SCMovieRecorder : NSObject
@property (atomic, readonly, getter=isRecording) BOOL recording;
@property (nonatomic, readonly) BOOL finished;
- (instancetype)initWithOutput:(AVCaptureMovieFileOutput *)output
                          URL:(NSURL *)url
                     delegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate
                  connections:(NSArray<AVCaptureConnection *> *)connections
                        audio:(BOOL)audio
                     rotation:(CGFloat)rotation
                     mirrored:(BOOL)mirrored
                        queue:(dispatch_queue_t)queue;
- (void)start;
- (void)appendVideo:(CVPixelBufferRef)pixels time:(CMTime)time;
- (void)stop;
@end
