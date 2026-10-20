//  SimCamInject.m — SimulatorCamera for iOS Simulator apps.
//
//  The iOS Simulator's capture stack (FigCaptureSourceSimulator) is a stub: it
//  never produces frames and AVCaptureDevice lists no cameras, not even the
//  Mac's own. This library is loaded into a simulator app at launch
//  (DYLD_INSERT_LIBRARIES) and supplies a camera through the normal
//  AVFoundation API, with frames read from the SimulatorCamera Mac app
//  (see SCFrameStore.h). Your app imports nothing.
//
//  Covered: device discovery (default/devices/DiscoverySession/uniqueID),
//  AVCaptureDeviceInput, AVCaptureSession running state + notifications,
//  AVCaptureVideoDataOutput (BGRA sample buffers), AVCaptureVideoPreviewLayer,
//  AVCaptureMetadataOutput (QR codes), AVCapturePhotoOutput (JPEG/HEIF data).
//  AVCaptureMovieFileOutput (H.264/AAC MOV, microphone via AVAudioEngine).
//  Without the Mac app running, a built-in animated test pattern is shown.
//
//  Simulator only. Build: SimulatorInjection/build.sh

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/mman.h>
#import <fcntl.h>
#import <stdatomic.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <errno.h>
#import "SCFrameStore.h"
#import "SCMovieRecorder.h"
#import "SCVideoGeometry.h"

#if !TARGET_OS_SIMULATOR
#error "SimCamInject is for the iOS Simulator only"
#endif

static NSString *const kSCDeviceID = @"com.dautov.SimulatorCamera.injected";
static void SCLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void SCLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SimulatorCamera] %@", s);
}

#pragma mark - Swizzling helpers

// -init replacements are plain C functions, so ARC would treat them as +0
// returns with an unowned self. Declare init-family ownership explicitly:
// self is consumed and the result is +1, matching what callers of -init expect.
#define SC_INIT_RESULT __attribute__((ns_returns_retained)) id
#define SC_INIT_SELF __attribute__((ns_consumed)) id
typedef SC_INIT_RESULT (*SCInitIMP1)(SC_INIT_SELF, SEL, id);
typedef SC_INIT_RESULT (*SCInitIMP2)(SC_INIT_SELF, SEL, id, NSError **);

static void SCSwizzleInstance(Class cls, SEL sel, IMP newImp, IMP *orig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { SCLog(@"missing -[%@ %@]", cls, NSStringFromSelector(sel)); return; }
    // Add on this class first so we never replace a superclass implementation.
    if (class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) {
        if (orig) *orig = method_getImplementation(m);
    } else {
        IMP old = method_setImplementation(m, newImp);
        if (orig) *orig = old;
    }
}

static void SCSwizzleClass(Class cls, SEL sel, IMP newImp, IMP *orig) {
    SCSwizzleInstance(object_getClass(cls), sel, newImp, orig);
}

#pragma mark - Fake objects
// AVFoundation classes have no public initializers for these objects, so the
// fakes are subclasses created without -init; every accessor apps use is
// overridden so the (uninitialised) superclass state is never read.

@interface SCDevice : AVCaptureDevice @end
@interface SCDeviceInput : AVCaptureDeviceInput @end
@interface SCConnection : AVCaptureConnection @end
@interface SCQRObject : AVMetadataMachineReadableCodeObject @end
@interface SCPhoto : AVCapturePhoto @end

static SCDevice *gDevice;
static SCDevice *SCSharedDevice(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gDevice = class_createInstance([SCDevice class], 0); });
    return gDevice;
}

@implementation SCDevice
- (NSString *)uniqueID { return kSCDeviceID; }
- (NSString *)modelID { return @"SimulatorCamera"; }
- (NSString *)localizedName { return @"SimulatorCamera"; }
- (NSString *)manufacturer { return @"SimulatorCamera"; }
- (BOOL)hasMediaType:(AVMediaType)t { return [t isEqualToString:AVMediaTypeVideo]; }
- (AVCaptureDevicePosition)position { return AVCaptureDevicePositionBack; }
- (AVCaptureDeviceType)deviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }
- (BOOL)isConnected { return YES; }
- (BOOL)isSuspended { return NO; }
- (BOOL)isInUseByAnotherApplication { return NO; }
- (NSArray *)formats { return @[]; }
- (AVCaptureDeviceFormat *)activeFormat { return nil; }
- (void)setActiveFormat:(AVCaptureDeviceFormat *)f {}
- (BOOL)lockForConfiguration:(NSError **)e { return YES; }
- (void)unlockForConfiguration {}
- (BOOL)supportsAVCaptureSessionPreset:(AVCaptureSessionPreset)p { return YES; }
- (BOOL)hasTorch { return NO; }
- (BOOL)hasFlash { return NO; }
- (BOOL)isTorchAvailable { return NO; }
- (BOOL)isTorchModeSupported:(AVCaptureTorchMode)m { return m == AVCaptureTorchModeOff; }
- (AVCaptureTorchMode)torchMode { return AVCaptureTorchModeOff; }
- (void)setTorchMode:(AVCaptureTorchMode)m {}
- (BOOL)isFocusModeSupported:(AVCaptureFocusMode)m { return YES; }
- (AVCaptureFocusMode)focusMode { return AVCaptureFocusModeContinuousAutoFocus; }
- (void)setFocusMode:(AVCaptureFocusMode)m {}
- (BOOL)isFocusPointOfInterestSupported { return YES; }
- (CGPoint)focusPointOfInterest { return CGPointMake(0.5, 0.5); }
- (void)setFocusPointOfInterest:(CGPoint)p {}
- (BOOL)isAutoFocusRangeRestrictionSupported { return NO; }
- (BOOL)isSmoothAutoFocusSupported { return NO; }
- (BOOL)isExposureModeSupported:(AVCaptureExposureMode)m { return YES; }
- (AVCaptureExposureMode)exposureMode { return AVCaptureExposureModeContinuousAutoExposure; }
- (void)setExposureMode:(AVCaptureExposureMode)m {}
- (BOOL)isExposurePointOfInterestSupported { return YES; }
- (CGPoint)exposurePointOfInterest { return CGPointMake(0.5, 0.5); }
- (void)setExposurePointOfInterest:(CGPoint)p {}
- (BOOL)isWhiteBalanceModeSupported:(AVCaptureWhiteBalanceMode)m { return YES; }
- (AVCaptureWhiteBalanceMode)whiteBalanceMode { return AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance; }
- (void)setWhiteBalanceMode:(AVCaptureWhiteBalanceMode)m {}
- (CGFloat)videoZoomFactor { return 1; }
- (void)setVideoZoomFactor:(CGFloat)f {}
- (void)rampToVideoZoomFactor:(CGFloat)f withRate:(float)r {}
- (void)cancelVideoZoomRamp {}
- (CGFloat)minAvailableVideoZoomFactor { return 1; }
- (CGFloat)maxAvailableVideoZoomFactor { return 1; }
- (BOOL)isSubjectAreaChangeMonitoringEnabled { return NO; }
- (void)setSubjectAreaChangeMonitoringEnabled:(BOOL)e {}
- (BOOL)isLowLightBoostSupported { return NO; }
- (CMTime)activeVideoMinFrameDuration { return CMTimeMake(1, 30); }
- (void)setActiveVideoMinFrameDuration:(CMTime)t {}
- (CMTime)activeVideoMaxFrameDuration { return CMTimeMake(1, 30); }
- (void)setActiveVideoMaxFrameDuration:(CMTime)t {}
- (NSArray *)constituentDevices { return @[]; }
- (BOOL)isVirtualDevice { return NO; }
- (float)lensAperture { return 1.8f; }
- (float)lensPosition { return 0.5f; }
- (NSString *)description { return @"<SCDevice SimulatorCamera (injected)>"; }
- (NSUInteger)hash { return kSCDeviceID.hash; }
- (BOOL)isEqual:(id)o { return o == self; }
@end

@implementation SCDeviceInput {
    @public SCDevice *_scDevice;
}
- (AVCaptureDevice *)device { return _scDevice; }
- (NSArray *)ports { return @[]; }
- (NSString *)description { return @"<SCDeviceInput SimulatorCamera>"; }
@end

@implementation SCConnection {
    @public AVCaptureVideoOrientation _orientation;
    @public CGFloat _rotation;
    @public BOOL _mirrored;
    @public AVMediaType _mediaType;
    @public __weak AVCaptureOutput *_output;
}
- (NSArray *)inputPorts { return @[]; }
- (AVMediaType)mediaType { return AVMediaTypeVideo; } // private, read by AVCaptureSession internals
- (AVCaptureDevice *)sourceDevice { return SCSharedDevice(); } // private, read by -canAddOutput:/-addOutput:
- (AVCaptureOutput *)output { return nil; }
- (AVCaptureVideoPreviewLayer *)videoPreviewLayer { return nil; }
- (BOOL)isEnabled { return YES; }
- (void)setEnabled:(BOOL)e {}
- (BOOL)isActive { return YES; }
- (BOOL)isVideoOrientationSupported { return YES; }
- (AVCaptureVideoOrientation)videoOrientation { return _orientation ?: AVCaptureVideoOrientationPortrait; }
- (void)setVideoOrientation:(AVCaptureVideoOrientation)o { _orientation = o; }
- (CGFloat)videoRotationAngle { return _rotation; }
- (void)setVideoRotationAngle:(CGFloat)a { _rotation = a; }
- (BOOL)isVideoRotationAngleSupported:(CGFloat)a { return YES; }
- (BOOL)isVideoMirroringSupported { return YES; }
- (BOOL)isVideoMirrored { return _mirrored; }
- (void)setVideoMirrored:(BOOL)m { _mirrored = m; }
- (BOOL)automaticallyAdjustsVideoMirroring { return NO; }
- (void)setAutomaticallyAdjustsVideoMirroring:(BOOL)a {}
- (BOOL)isVideoStabilizationSupported { return NO; }
- (AVCaptureVideoStabilizationMode)preferredVideoStabilizationMode { return AVCaptureVideoStabilizationModeOff; }
- (void)setPreferredVideoStabilizationMode:(AVCaptureVideoStabilizationMode)m {}
- (AVCaptureVideoStabilizationMode)activeVideoStabilizationMode { return AVCaptureVideoStabilizationModeOff; }
- (BOOL)isCameraIntrinsicMatrixDeliverySupported { return NO; }
- (void)setCameraIntrinsicMatrixDeliveryEnabled:(BOOL)e {}
- (CMTime)videoMinFrameDuration { return CMTimeMake(1, 30); }
- (void)setVideoMinFrameDuration:(CMTime)t {}
@end

static SCConnection *SCNewConnection(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // This fake never initializes AVCaptureConnection's native graph. Its
        // dealloc assumes that graph exists and crashes when a preview releases
        // its connection. NSObject still runs ARC ivar/weak/association cleanup.
        SEL dealloc = sel_registerName("dealloc");
        Method rootDealloc = class_getInstanceMethod([NSObject class], dealloc);
        class_addMethod([SCConnection class], dealloc, method_getImplementation(rootDealloc),
                        method_getTypeEncoding(rootDealloc));
    });
    SCConnection *c = class_createInstance([SCConnection class], 0);
    c->_orientation = AVCaptureVideoOrientationPortrait;
    c->_rotation = 90;
    return c;
}

@implementation SCQRObject {
    @public NSString *_value;
    @public CGRect _bounds;
    @public NSArray *_corners;
    @public CMTime _time;
}
- (AVMetadataObjectType)type { return AVMetadataObjectTypeQRCode; }
- (NSString *)stringValue { return _value; }
- (CGRect)bounds { return _bounds; }
- (NSArray *)corners { return _corners; }
- (CMTime)time { return _time; }
- (CMTime)duration { return kCMTimeInvalid; }
- (CIBarcodeDescriptor *)descriptor { return nil; }
- (NSString *)description { return [NSString stringWithFormat:@"<SCQRObject %@>", _value]; }
@end

@implementation SCPhoto {
    @public CVPixelBufferRef _pixels;
    @public NSData *_data;
    @public CMTime _time;
}
- (CMTime)timestamp { return _time; }
- (BOOL)isRawPhoto { return NO; }
- (CVPixelBufferRef)pixelBuffer { return _pixels; }
- (CVPixelBufferRef)previewPixelBuffer { return _pixels; }
- (NSDictionary *)metadata { return @{}; }
- (NSData *)fileDataRepresentation { return _data; }
- (CGImageRef)CGImageRepresentation {
    CIImage *ci = [CIImage imageWithCVPixelBuffer:_pixels];
    CGImageRef img = [[CIContext context] createCGImage:ci fromRect:ci.extent];
    return (CGImageRef)CFAutorelease(img);
}
- (CGImageRef)previewCGImageRepresentation { return [self CGImageRepresentation]; }
- (NSInteger)photoCount { return 1; }
- (AVCaptureResolvedPhotoSettings *)resolvedSettings { return nil; }
@end

// The fakes never ran their AVFoundation -init, so the AVFoundation -dealloc
// would tear down internals that were never set up (it crashes in
// -[AVCaptureConnection dealloc]). Go straight to NSObject's -dealloc, which
// still releases our ivars (.cxx_destruct) and associated objects.
static void SCFakeDealloc(__unsafe_unretained id self, SEL _cmd) {
    if ([self isKindOfClass:[SCPhoto class]]) {
        __unsafe_unretained SCPhoto *p = self;
        if (p->_pixels) CVPixelBufferRelease(p->_pixels);
        p->_pixels = NULL;
    }
    struct objc_super sup = { self, [NSObject class] };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
}

static void SCInstallFakeDealloc(void) {
    SEL dealloc = sel_registerName("dealloc"); // ARC disallows @selector(dealloc)
    for (Class c in @[[SCDevice class], [SCDeviceInput class], [SCConnection class], [SCQRObject class], [SCPhoto class]])
        class_replaceMethod(c, dealloc, (IMP)SCFakeDealloc, "v@:");
}

#pragma mark - Frame source (Mac app frame file, or built-in test pattern)

static uint8_t *gStore;           // mmap of SC_FRAME_STORE_PATH, read-only
static uint64_t gLastSeq;
static CVPixelBufferRef gLatest;  // newest delivered frame (Mac or pattern), owned
static CVPixelBufferRef gStoreLatest; // newest complete frame from the Mac app, owned
static double gStoreLatestAt;     // when gStoreLatest was read (seconds since 1970)
static uint64_t gFrameCount;
static dispatch_queue_t gFrameQueue;
static int gBridgeSocket = -1; // A live socket is the host hardware lease; owned on gFrameQueue.

static void SCResetStore(void) {
    if (gStore) { munmap(gStore, SC_FRAME_FILE_SIZE); gStore = NULL; }
    if (gLatest) { CVPixelBufferRelease(gLatest); gLatest = NULL; }
    if (gStoreLatest) { CVPixelBufferRelease(gStoreLatest); gStoreLatest = NULL; }
    gLastSeq = 0;
    gStoreLatestAt = 0;
}

static void SCReleaseBridge(void) {
    if (gBridgeSocket < 0) return;
    // The next take gets a new frame-store inode. Drop mappings before releasing
    // the host writer, rather than showing a stale frame from the previous take.
    SCResetStore();
    close(gBridgeSocket);
    gBridgeSocket = -1;
}

static BOOL SCAcquireBridge(void) {
    const char *path = getenv("SIMCAM_BRIDGE_SOCKET");
    if (!path || !*path || gBridgeSocket >= 0) return YES;
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (strlen(path) >= sizeof(address.sun_path)) return NO;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    int noSignal = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    struct timeval timeout = { .tv_sec = 12 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    char ready = 0;
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        send(fd, "CAPTURE\n", 8, 0) != 8 || recv(fd, &ready, 1, 0) != 1 || ready != 'R') {
        close(fd);
        SCLog(@"host camera bridge unavailable or failed to start");
        return NO;
    }
    SCResetStore();
    gBridgeSocket = fd;
    return YES;
}

static void SCMapStore(void) {
    if (gStore) return;
    int fd = open(SC_FRAME_STORE_PATH, O_RDONLY);
    if (fd < 0) return;
    void *p = mmap(NULL, SC_FRAME_FILE_SIZE, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (p != MAP_FAILED) gStore = p;
}

static CVPixelBufferRef SCNewBuffer(size_t w, size_t h) {
    NSDictionary *attrs = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                             (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
                             (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES };
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pb);
    return pb;
}

/// Copy the Mac app's newest frame if there is a fresh, complete one.
static CVPixelBufferRef SCReadStoreOnce(void) {
    SCMapStore();
    if (!gStore) return NULL;
    const SCFrameHeader *h = (const SCFrameHeader *)gStore;
    if (h->magic != SC_FRAME_MAGIC) return NULL;
    uint64_t s1 = atomic_load_explicit((_Atomic uint64_t *)&h->seq, memory_order_acquire);
    if (s1 & 1) return NULL;
    // Treat a writer that stopped more than 3 s ago as gone.
    if ([NSDate date].timeIntervalSince1970 - h->hostTime > 3 && h->hostTime > 1e9) return NULL;
    uint32_t w = h->width, ht = h->height, bpr = h->bytesPerRow, sourceKind = h->sourceKind;
    if (!w || !ht || w > SC_FRAME_MAX_WIDTH || ht > SC_FRAME_MAX_HEIGHT || bpr < w * 4 || (uint64_t)bpr * ht > SC_FRAME_MAX_BYTES) return NULL;
    if (s1 == gLastSeq && gStoreLatest && CVPixelBufferGetWidth(gStoreLatest) == w) return CVPixelBufferRetain(gStoreLatest);
    CVPixelBufferRef pb = SCNewBuffer(w, ht);
    if (!pb) return NULL;
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst = CVPixelBufferGetBaseAddress(pb);
    size_t dbpr = CVPixelBufferGetBytesPerRow(pb);
    const uint8_t *src = gStore + SC_FRAME_HEADER_SIZE;
    for (uint32_t y = 0; y < ht; y++) memcpy(dst + y * dbpr, src + (size_t)y * bpr, w * 4);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    uint64_t s2 = atomic_load_explicit((_Atomic uint64_t *)&h->seq, memory_order_acquire);
    if (s1 != s2) { CVPixelBufferRelease(pb); return NULL; } // torn; keep previous
    CVBufferSetAttachment(pb, SCFrameSourceKindKey, (__bridge CFNumberRef)@(sourceKind), kCVAttachmentMode_ShouldPropagate);
    gLastSeq = s1;
    return pb;
}

/// The Mac app's frame, or its last good frame if we caught a write in progress.
/// NULL once the Mac app has been quiet for 1 s (then the test pattern shows).
static CVPixelBufferRef SCReadStore(void) {
    double now = [NSDate date].timeIntervalSince1970;
    CVPixelBufferRef pb = SCReadStoreOnce();
    if (pb) {
        if (pb != gStoreLatest) {
            if (gStoreLatest) CVPixelBufferRelease(gStoreLatest);
            gStoreLatest = CVPixelBufferRetain(pb);
        }
        gStoreLatestAt = now;
        return pb;
    }
    if (gStoreLatest && now - gStoreLatestAt < 1.0) return CVPixelBufferRetain(gStoreLatest);
    return NULL;
}

/// Animated colour bars with a moving stripe, so a stuck pipeline is visible.
static CVPixelBufferRef SCTestPattern(uint64_t n) {
    const size_t w = 1280, h = 720;
    CVPixelBufferRef pb = SCNewBuffer(w, h);
    if (!pb) return NULL;
    CVPixelBufferLockBaseAddress(pb, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), w, h, 8, CVPixelBufferGetBytesPerRow(pb), cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    const CGFloat bars[7][3] = {{.75,.75,.75},{.75,.75,0},{0,.75,.75},{0,.75,0},{.75,0,.75},{.75,0,0},{0,0,.75}};
    for (int i = 0; i < 7; i++) {
        CGContextSetRGBFillColor(ctx, bars[i][0], bars[i][1], bars[i][2], 1);
        CGContextFillRect(ctx, CGRectMake(i * w / 7.0, 0, w / 7.0 + 1, h));
    }
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 0.85);
    CGContextFillRect(ctx, CGRectMake((n * 8) % w, 0, 24, h));
    CGContextSetRGBFillColor(ctx, 0, 0, 0, 0.6);
    CGContextFillRect(ctx, CGRectMake(0, h / 2 - 60, w, 120));
    UIGraphicsPushContext(ctx);
    CGContextTranslateCTM(ctx, 0, h); CGContextScaleCTM(ctx, 1, -1);
    NSDictionary *a = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:44], NSForegroundColorAttributeName: UIColor.whiteColor };
    [@"SimulatorCamera — open the Mac app for live frames" drawAtPoint:CGPointMake(40, h / 2 - 28) withAttributes:a];
    UIGraphicsPopContext();
    CGContextRelease(ctx); CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

#pragma mark - Session registry

static const void *kSCMovieKey = &kSCMovieKey;
static void SCUpdateTimer(void);
static void sc_stopRunning(AVCaptureSession *self, SEL cmd);
@interface SCWeakSession : NSObject
@property (nonatomic, weak) AVCaptureSession *session;
@end
@implementation SCWeakSession @end

@interface SCSessionState : NSObject
@property (nonatomic) BOOL usesFake; // Sticky: an injected session never resumes the native stub graph.
@property (nonatomic) BOOL running;
@property (nonatomic, strong) NSMutableArray *inputs;
@property (nonatomic, strong) NSHashTable *outputs;
@end
@implementation SCSessionState
- (instancetype)init { if ((self = [super init])) { _inputs = [NSMutableArray array]; _outputs = [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory]; } return self; }
- (void)dealloc {
    for (AVCaptureOutput *output in _outputs.allObjects) {
        SCMovieRecorder *recorder = objc_getAssociatedObject(output, kSCMovieKey);
        if (recorder) dispatch_async(gFrameQueue, ^{ [recorder stop]; });
    }
    dispatch_async(gFrameQueue, ^{ SCUpdateTimer(); });
}
@end

static const void *kSCStateKey = &kSCStateKey;
static const void *kSCSessionKey = &kSCSessionKey;        // output/layer -> session (weak box)
static const void *kSCConnKey = &kSCConnKey;              // output/layer -> SCConnection
static const void *kSCAudioConnKey = &kSCAudioConnKey;
static const void *kSCPreviewSessionKey = &kSCPreviewSessionKey;
static const void *kSCMetaTypesKey = &kSCMetaTypesKey;
static const void *kSCRectKey = &kSCRectKey;
static NSHashTable *gRunning;       // running fake sessions (weak)
static NSHashTable *gLayers;        // preview layers (weak)
static dispatch_source_t gTimer;
static CIDetector *gQR;
static NSLock *gLock;

static SCSessionState *SCState(AVCaptureSession *s) {
    SCSessionState *st = objc_getAssociatedObject(s, kSCStateKey);
    if (!st) { st = [SCSessionState new]; objc_setAssociatedObject(s, kSCStateKey, st, OBJC_ASSOCIATION_RETAIN); }
    return st;
}

static AVCaptureSession *SCSessionFor(id object) {
    SCWeakSession *box = objc_getAssociatedObject(object, kSCSessionKey);
    return box.session;
}

static NSArray *SCOutputs(AVCaptureSession *session) {
    SCSessionState *state = SCState(session);
    @synchronized (state) { return state.outputs.allObjects; }
}

static SCConnection *SCConnectionFor(id obj) {
    SCConnection *c = objc_getAssociatedObject(obj, kSCConnKey);
    if (!c) { c = SCNewConnection(); objc_setAssociatedObject(obj, kSCConnKey, c, OBJC_ASSOCIATION_RETAIN); }
    return c;
}

static BOOL SCHasAudio(AVCaptureSession *session) {
    for (AVCaptureInput *input in session.inputs)
        if ([input isKindOfClass:AVCaptureDeviceInput.class] && [((AVCaptureDeviceInput *)input).device hasMediaType:AVMediaTypeAudio]) return YES;
    return NO;
}

static BOOL SCHasVideo(AVCaptureSession *session) {
    for (AVCaptureInput *input in SCState(session).inputs)
        if ([input isKindOfClass:SCDeviceInput.class]) return YES;
    return NO;
}

static SCConnection *SCAudioConnectionFor(AVCaptureOutput *output) {
    SCConnection *c = objc_getAssociatedObject(output, kSCAudioConnKey);
    if (!c) {
        c = SCNewConnection(); c->_mediaType = AVMediaTypeAudio; c->_output = output;
        objc_setAssociatedObject(output, kSCAudioConnKey, c, OBJC_ASSOCIATION_RETAIN);
    }
    return c;
}

static CMSampleBufferRef SCSampleBuffer(CVPixelBufferRef pb, CMTime pts) {
    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt) != noErr) return NULL;
    CMSampleTimingInfo t = { CMTimeMake(1, 30), pts, kCMTimeInvalid };
    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fmt, &t, &sb);
    CFRelease(fmt);
    return sb;
}

static void SCDeliverMetadata(AVCaptureMetadataOutput *out, AVCaptureSession *session, CVPixelBufferRef pb, CMTime pts) {
    NSArray *wanted = objc_getAssociatedObject(out, kSCMetaTypesKey);
    if (![wanted containsObject:AVMetadataObjectTypeQRCode]) return;
    id<AVCaptureMetadataOutputObjectsDelegate> d = out.metadataObjectsDelegate;
    dispatch_queue_t q = out.metadataObjectsCallbackQueue;
    if (!d || !q || ![d respondsToSelector:@selector(captureOutput:didOutputMetadataObjects:fromConnection:)]) return;
    CIImage *img = [CIImage imageWithCVPixelBuffer:pb];
    NSArray<CIFeature *> *found = [gQR featuresInImage:img];
    if (!found.count) return;
    CGFloat W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb);
    NSMutableArray *objs = [NSMutableArray array];
    for (CIQRCodeFeature *f in found) {
        if (![f isKindOfClass:[CIQRCodeFeature class]] || !f.messageString) continue;
        SCQRObject *o = class_createInstance([SCQRObject class], 0);
        // Metadata coordinates are normalised, origin top-left (CI is bottom-left).
        CGRect b = f.bounds;
        o->_bounds = CGRectMake(b.origin.x / W, 1 - (b.origin.y + b.size.height) / H, b.size.width / W, b.size.height / H);
        NSDictionary *(^pt)(CGPoint) = ^(CGPoint p) { return (__bridge_transfer NSDictionary *)CGPointCreateDictionaryRepresentation(CGPointMake(p.x / W, 1 - p.y / H)); };
        o->_corners = @[pt(f.topLeft), pt(f.topRight), pt(f.bottomRight), pt(f.bottomLeft)];
        o->_value = f.messageString;
        o->_time = pts;
        [objs addObject:o];
    }
    if (!objs.count) return;
    AVCaptureConnection *c = SCConnectionFor(out);
    dispatch_async(q, ^{ [d captureOutput:out didOutputMetadataObjects:objs fromConnection:c]; });
}

static void SCTick(void) {
    if (gBridgeSocket >= 0) {
        char byte;
        ssize_t count = recv(gBridgeSocket, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
        if (count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
            SCReleaseBridge();
            [gLock lock]; NSArray *sessions = gRunning.allObjects; [gLock unlock];
            NSError *error = [NSError errorWithDomain:AVFoundationErrorDomain code:AVErrorUnknown
                userInfo:@{NSLocalizedDescriptionKey: @"The host camera bridge disconnected"}];
            for (AVCaptureSession *session in sessions) {
                sc_stopRunning(session, @selector(stopRunning));
                [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionRuntimeErrorNotification
                    object:session userInfo:@{AVCaptureSessionErrorKey: error}];
            }
            return;
        }
    }
    gFrameCount++;
    CVPixelBufferRef pb = SCReadStore();
    if (!pb && !getenv("SIMCAM_BRIDGE_SOCKET")) pb = SCTestPattern(gFrameCount);
    if (!pb) return;
    if (gLatest) CVPixelBufferRelease(gLatest);
    gLatest = CVPixelBufferRetain(pb);
    CMTime pts = CMClockGetTime(CMClockGetHostTimeClock());

    [gLock lock];
    NSArray *sessions = gRunning.allObjects;
    NSArray *layers = gLayers.allObjects;
    [gLock unlock];

    for (AVCaptureSession *s in sessions) {
        for (AVCaptureOutput *out in SCOutputs(s)) {
            if ([out isKindOfClass:[AVCaptureMovieFileOutput class]]) {
#if SIMCAM_RECORDING_TESTS
                if (getenv("SC_TEST_NO_VIDEO")) continue;
#endif
                SCMovieRecorder *recorder = objc_getAssociatedObject(out, kSCMovieKey);
                [recorder appendVideo:pb time:pts];
            } else if ([out isKindOfClass:[AVCaptureVideoDataOutput class]]) {
                AVCaptureVideoDataOutput *vo = (AVCaptureVideoDataOutput *)out;
                id<AVCaptureVideoDataOutputSampleBufferDelegate> d = vo.sampleBufferDelegate;
                dispatch_queue_t q = vo.sampleBufferCallbackQueue;
                if (!d || !q || ![d respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) continue;
                CMSampleBufferRef sb = SCSampleBuffer(pb, pts);
                if (!sb) continue;
                AVCaptureConnection *c = SCConnectionFor(vo);
                dispatch_async(q, ^{ [d captureOutput:vo didOutputSampleBuffer:sb fromConnection:c]; CFRelease(sb); });
            } else if ([out isKindOfClass:[AVCaptureMetadataOutput class]] && gFrameCount % 6 == 0) {
                SCDeliverMetadata((AVCaptureMetadataOutput *)out, s, pb, pts);
            }
        }
    }

    if (layers.count && gFrameCount % 2 == 0) { // preview at 15 fps is plenty
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
        static CIContext *ctx; if (!ctx) ctx = [CIContext context];
        NSMutableArray *frames = [NSMutableArray array];
        CGFloat portraitRotation = SCFramePortraitRotation(pb);
        CGSize size = CGSizeMake(CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb));
        for (AVCaptureVideoPreviewLayer *layer in layers) {
            CIImage *display = ci;
            if (portraitRotation != 0) {
                SCConnection *connection = SCConnectionFor(layer);
                CGAffineTransform transform = SCVideoDisplayTransform(size, connection->_rotation, connection->_mirrored, portraitRotation);
                CGRect bounds = CGRectApplyAffineTransform((CGRect){CGPointZero, size}, transform);
                // Core Image uses bottom-left coordinates; the movie/display transform
                // uses top-left coordinates. Convert both ends, not the rotation rule.
                CGAffineTransform ciTransform = CGAffineTransformConcat(CGAffineTransformMake(1, 0, 0, -1, 0, size.height), transform);
                ciTransform = CGAffineTransformConcat(ciTransform, CGAffineTransformMake(1, 0, 0, -1, 0, bounds.size.height));
                display = [ci imageByApplyingTransform:ciTransform];
            }
            CGImageRef image = [ctx createCGImage:display fromRect:display.extent];
            if (image) { [frames addObject:@[layer, (__bridge id)image]]; CGImageRelease(image); }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [CATransaction begin];
            [CATransaction setDisableActions:YES]; // no cross-fade between frames
            for (NSArray *frame in frames) {
                AVCaptureVideoPreviewLayer *l = frame[0];
                AVCaptureSession *s = l.session;
                if (!s || !SCState(s).running) continue;
                NSString *g = l.videoGravity;
                l.contentsGravity = [g isEqualToString:AVLayerVideoGravityResize] ? kCAGravityResize
                                  : [g isEqualToString:AVLayerVideoGravityResizeAspect] ? kCAGravityResizeAspect
                                  : kCAGravityResizeAspectFill;
                l.contents = frame[1];
            }
            [CATransaction commit];
        });
    }
    CVPixelBufferRelease(pb);
}

static void SCUpdateTimer(void) {
    // Sessions are controlled on caller queues; timer ownership stays on the frame queue.
    dispatch_async(gFrameQueue, ^{
    [gLock lock];
    BOOL any = gRunning.allObjects.count > 0;
    [gLock unlock];
    if (any && !gTimer) {
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gFrameQueue);
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC / 30, NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gTimer, ^{ @autoreleasepool { SCTick(); } });
        dispatch_resume(gTimer);
    } else if (!any && gTimer) {
        dispatch_source_cancel(gTimer);
        gTimer = nil;
    }
    if (!any) SCReleaseBridge();
    });
}

#pragma mark - AVCaptureDevice discovery

static IMP o_defaultDevice, o_defaultDeviceType, o_devicesWithMediaType, o_devices, o_deviceWithUniqueID, o_discoveryDevices;

static AVCaptureDevice *sc_defaultDevice(id self, SEL _cmd, AVMediaType t) {
    if ([t isEqualToString:AVMediaTypeVideo]) return SCSharedDevice();
    return ((AVCaptureDevice *(*)(id, SEL, AVMediaType))o_defaultDevice)(self, _cmd, t);
}
static AVCaptureDevice *sc_defaultDeviceType(id self, SEL _cmd, AVCaptureDeviceType dt, AVMediaType t, AVCaptureDevicePosition p) {
    if (!t || [t isEqualToString:AVMediaTypeVideo]) {
        BOOL frontOnly = p == AVCaptureDevicePositionFront;
        if (!frontOnly || getenv("SIMCAM_ANY_POSITION")) return SCSharedDevice();
    }
    return ((AVCaptureDevice *(*)(id, SEL, AVCaptureDeviceType, AVMediaType, AVCaptureDevicePosition))o_defaultDeviceType)(self, _cmd, dt, t, p);
}
static NSArray *sc_devicesWithMediaType(id self, SEL _cmd, AVMediaType t) {
    NSArray *r = ((NSArray *(*)(id, SEL, AVMediaType))o_devicesWithMediaType)(self, _cmd, t);
    return [t isEqualToString:AVMediaTypeVideo] ? [@[SCSharedDevice()] arrayByAddingObjectsFromArray:r] : r;
}
static NSArray *sc_devices(id self, SEL _cmd) {
    NSArray *r = ((NSArray *(*)(id, SEL))o_devices)(self, _cmd);
    return [@[SCSharedDevice()] arrayByAddingObjectsFromArray:r];
}
static AVCaptureDevice *sc_deviceWithUniqueID(id self, SEL _cmd, NSString *uid) {
    if ([uid isEqualToString:kSCDeviceID]) return SCSharedDevice();
    return ((AVCaptureDevice *(*)(id, SEL, NSString *))o_deviceWithUniqueID)(self, _cmd, uid);
}
static NSArray *sc_discoveryDevices(AVCaptureDeviceDiscoverySession *self, SEL _cmd) {
    NSArray *r = ((NSArray *(*)(id, SEL))o_discoveryDevices)(self, _cmd);
    // The discovery session stores its media type privately; only video sessions reach here in practice.
    return [@[SCSharedDevice()] arrayByAddingObjectsFromArray:r ?: @[]];
}

#pragma mark - AVCaptureDeviceInput

static IMP o_inputInit, o_inputFactory;

static SCDeviceInput *SCMakeInput(AVCaptureDevice *d) {
    SCDeviceInput *in = class_createInstance([SCDeviceInput class], 0);
    in->_scDevice = (SCDevice *)d;
    return in;
}
static SC_INIT_RESULT sc_inputInit(SC_INIT_SELF self, SEL _cmd, AVCaptureDevice *d, NSError **e) {
    if ([d isKindOfClass:[SCDevice class]]) {
        // Keep the alloc'd-but-uninitialised receiver alive rather than
        // running AVCaptureDeviceInput's -dealloc on it.
        (void)CFBridgingRetain(self);
        return SCMakeInput(d);
    }
    return ((SCInitIMP2)o_inputInit)(self, _cmd, d, e);
}
static id sc_inputFactory(id self, SEL _cmd, AVCaptureDevice *d, NSError **e) {
    if ([d isKindOfClass:[SCDevice class]]) return SCMakeInput(d);
    return ((id (*)(id, SEL, AVCaptureDevice *, NSError **))o_inputFactory)(self, _cmd, d, e);
}

#pragma mark - AVCaptureSession

static IMP o_canAddInput, o_addInput, o_removeInput, o_inputs, o_outputs, o_addOutput, o_removeOutput,
            o_startRunning, o_stopRunning, o_isRunning, o_canAddOutput, o_addInputNoConn;
static void sc_stopRunning(AVCaptureSession *self, SEL cmd);

static BOOL sc_canAddInput(AVCaptureSession *self, SEL _cmd, AVCaptureInput *in) {
    if ([in isKindOfClass:[SCDeviceInput class]]) return YES;
    if (SCState(self).usesFake && [in isKindOfClass:AVCaptureDeviceInput.class] && [((AVCaptureDeviceInput *)in).device hasMediaType:AVMediaTypeAudio]) return YES;
    return ((BOOL (*)(id, SEL, id))o_canAddInput)(self, _cmd, in);
}
static void sc_addInput(AVCaptureSession *self, SEL _cmd, AVCaptureInput *in) {
    SCSessionState *st = SCState(self);
    BOOL fakeVideo = [in isKindOfClass:SCDeviceInput.class];
    BOOL audio = [in isKindOfClass:AVCaptureDeviceInput.class] && [((AVCaptureDeviceInput *)in).device hasMediaType:AVMediaTypeAudio];
    if (fakeVideo || (st.usesFake && audio)) {
        if (![st.inputs containsObject:in]) [st.inputs addObject:in];
        if (fakeVideo) st.usesFake = YES;
        // Keep a real, permission-checked microphone input, but do not add it to
        // the Simulator's stub graph: that graph emits spurious runtime failures.
        return;
    }
    ((void (*)(id, SEL, id))o_addInput)(self, _cmd, in);
}
static void sc_removeInput(AVCaptureSession *self, SEL _cmd, AVCaptureInput *in) {
    SCSessionState *st = SCState(self);
    if ([st.inputs containsObject:in]) {
        if (st.running) sc_stopRunning(self, @selector(stopRunning));
        [st.inputs removeObject:in];
        return;
    }
    ((void (*)(id, SEL, id))o_removeInput)(self, _cmd, in);
}
static NSArray *sc_inputs(AVCaptureSession *self, SEL _cmd) {
    NSArray *r = ((NSArray *(*)(id, SEL))o_inputs)(self, _cmd);
    SCSessionState *st = objc_getAssociatedObject(self, kSCStateKey);
    return st.inputs.count ? [st.inputs arrayByAddingObjectsFromArray:r] : r;
}
static BOOL sc_canAddOutput(AVCaptureSession *self, SEL _cmd, AVCaptureOutput *o) {
    // The stock check walks existing outputs' (fake) connections; skip it.
    if (SCState(self).usesFake) return ![SCState(self).outputs containsObject:o];
    return ((BOOL (*)(id, SEL, id))o_canAddOutput)(self, _cmd, o);
}
static void sc_addOutput(AVCaptureSession *self, SEL _cmd, AVCaptureOutput *o) {
    SCSessionState *state = SCState(self);
    @synchronized (state) { [state.outputs addObject:o]; }
    SCWeakSession *box = [SCWeakSession new]; box.session = self;
    objc_setAssociatedObject(o, kSCSessionKey, box, OBJC_ASSOCIATION_RETAIN);
    if (state.usesFake) return;
    @try { ((void (*)(id, SEL, id))o_addOutput)(self, _cmd, o); }
    @catch (NSException *ex) { SCLog(@"addOutput fallback (%@)", ex.reason); }
}
static void sc_removeOutput(AVCaptureSession *self, SEL _cmd, AVCaptureOutput *o) {
    SCMovieRecorder *recorder = objc_getAssociatedObject(o, kSCMovieKey);
    if (recorder) dispatch_async(gFrameQueue, ^{ [recorder stop]; });
    SCSessionState *state = SCState(self);
    @synchronized (state) { [state.outputs removeObject:o]; }
    if (!state.usesFake) { @try { ((void (*)(id, SEL, id))o_removeOutput)(self, _cmd, o); } @catch (NSException *ex) {} }
    objc_setAssociatedObject(o, kSCSessionKey, nil, OBJC_ASSOCIATION_RETAIN);
}
static NSArray *sc_outputs(AVCaptureSession *self, SEL cmd) {
    if (SCState(self).usesFake) return SCOutputs(self);
    return ((id (*)(id, SEL))o_outputs)(self, cmd);
}
static void sc_startRunning(AVCaptureSession *self, SEL _cmd) {
    SCSessionState *st = SCState(self);
    if (!st.usesFake) { ((void (*)(id, SEL))o_startRunning)(self, _cmd); return; }
    if (!SCHasVideo(self)) return;
    if (st.running) return;
    __block BOOL ready = NO;
    dispatch_sync(gFrameQueue, ^{
        ready = SCAcquireBridge();
        if (ready) {
            st.running = YES;
            [gLock lock]; [gRunning addObject:self]; [gLock unlock];
        }
    });
    if (!ready) return;
    SCUpdateTimer();
    SCLog(@"session running with the injected camera");
    [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionDidStartRunningNotification object:self];
}
static void sc_stopRunning(AVCaptureSession *self, SEL _cmd) {
    SCSessionState *st = SCState(self);
    if (!st.usesFake) { ((void (*)(id, SEL))o_stopRunning)(self, _cmd); return; }
    if (!st.running) return;
    for (AVCaptureOutput *output in SCOutputs(self)) {
        SCMovieRecorder *recorder = objc_getAssociatedObject(output, kSCMovieKey);
        if (recorder) dispatch_async(gFrameQueue, ^{ [recorder stop]; });
    }
    st.running = NO;
    [gLock lock]; [gRunning removeObject:self]; [gLock unlock];
    SCUpdateTimer();
    [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionDidStopRunningNotification object:self];
}
static IMP o_beginConfig, o_commitConfig;
// Never commit an injected graph into the native simulator stub. Even an empty
// native commit emits runtime errors that would interrupt a valid emulated take.
// If begin preceded the fake input, its native transaction stays quarantined
// until session destruction. usesFake stays set even after removing the camera.
static void sc_beginConfig(AVCaptureSession *self, SEL _cmd) {
    SCSessionState *st = SCState(self);
    if (st.usesFake) return;
    ((void (*)(id, SEL))o_beginConfig)(self, _cmd);
}
static void sc_commitConfig(AVCaptureSession *self, SEL _cmd) {
    SCSessionState *st = SCState(self);
    if (st.usesFake) return;
    ((void (*)(id, SEL))o_commitConfig)(self, _cmd);
}
static BOOL sc_isRunning(AVCaptureSession *self, SEL _cmd) {
    SCSessionState *st = objc_getAssociatedObject(self, kSCStateKey);
    if (st.usesFake) return st.running;
    return ((BOOL (*)(id, SEL))o_isRunning)(self, _cmd);
}

#pragma mark - Outputs and preview layer

static IMP o_connectionWithMediaType, o_connections, o_setMetaTypes, o_metaTypes, o_availableMetaTypes,
           o_layerConnection, o_layerSession, o_layerSetSession, o_layerInitSession, o_layerInitNoConn, o_transformMeta,
           o_capturePhoto, o_setRectOfInterest, o_rectOfInterest;

static BOOL SCOutputIsFake(id out) {
    AVCaptureSession *s = SCSessionFor(out);
    SCSessionState *st = s ? objc_getAssociatedObject(s, kSCStateKey) : nil;
    return st.usesFake;
}
static AVCaptureConnection *sc_connectionWithMediaType(AVCaptureOutput *self, SEL _cmd, AVMediaType t) {
    if (SCOutputIsFake(self)) {
        if ([t isEqualToString:AVMediaTypeVideo]) {
            if (!SCHasVideo(SCSessionFor(self))) return nil;
            SCConnection *c = SCConnectionFor(self); c->_output = self; return c;
        }
        if ([t isEqualToString:AVMediaTypeAudio] && [self isKindOfClass:AVCaptureMovieFileOutput.class] && SCHasAudio(SCSessionFor(self))) return SCAudioConnectionFor(self);
        return nil;
    }
    return ((id (*)(id, SEL, id))o_connectionWithMediaType)(self, _cmd, t);
}
static NSArray *sc_connections(AVCaptureOutput *self, SEL _cmd) {
    if (SCOutputIsFake(self)) {
        AVCaptureConnection *video = sc_connectionWithMediaType(self, @selector(connectionWithMediaType:), AVMediaTypeVideo);
        AVCaptureConnection *audio = sc_connectionWithMediaType(self, @selector(connectionWithMediaType:), AVMediaTypeAudio);
        if (!video) return audio ? @[audio] : @[];
        return audio ? @[video, audio] : @[video];
    }
    return ((id (*)(id, SEL))o_connections)(self, _cmd);
}
static void sc_setMetaTypes(AVCaptureMetadataOutput *self, SEL _cmd, NSArray *types) {
    objc_setAssociatedObject(self, kSCMetaTypesKey, [types copy], OBJC_ASSOCIATION_RETAIN);
    if (SCOutputIsFake(self)) return; // the stock call throws: no real input to validate against
    ((void (*)(id, SEL, id))o_setMetaTypes)(self, _cmd, types);
}
static NSArray *sc_metaTypes(AVCaptureMetadataOutput *self, SEL _cmd) {
    if (SCOutputIsFake(self)) return objc_getAssociatedObject(self, kSCMetaTypesKey) ?: @[];
    return ((id (*)(id, SEL))o_metaTypes)(self, _cmd);
}
static NSArray *sc_availableMetaTypes(AVCaptureMetadataOutput *self, SEL _cmd) {
    if (SCOutputIsFake(self)) return @[AVMetadataObjectTypeQRCode];
    return ((id (*)(id, SEL))o_availableMetaTypes)(self, _cmd);
}
static void sc_setRectOfInterest(AVCaptureMetadataOutput *self, SEL _cmd, CGRect r) {
    objc_setAssociatedObject(self, kSCRectKey, [NSValue valueWithCGRect:r], OBJC_ASSOCIATION_RETAIN);
    if (SCOutputIsFake(self)) return;
    ((void (*)(id, SEL, CGRect))o_setRectOfInterest)(self, _cmd, r);
}
static CGRect sc_rectOfInterest(AVCaptureMetadataOutput *self, SEL _cmd) {
    if (SCOutputIsFake(self)) { NSValue *v = objc_getAssociatedObject(self, kSCRectKey); return v ? v.CGRectValue : CGRectMake(0, 0, 1, 1); }
    return ((CGRect (*)(id, SEL))o_rectOfInterest)(self, _cmd);
}

static void SCTrackLayer(AVCaptureVideoPreviewLayer *l) {
    [gLock lock]; [gLayers addObject:l]; [gLock unlock];
}
static AVCaptureConnection *sc_layerConnection(AVCaptureVideoPreviewLayer *self, SEL _cmd) {
    AVCaptureSession *s = self.session;
    SCSessionState *st = s ? objc_getAssociatedObject(s, kSCStateKey) : nil;
    if (st.usesFake || objc_getAssociatedObject(self, kSCPreviewSessionKey)) return SCConnectionFor(self);
    return ((id (*)(id, SEL))o_layerConnection)(self, _cmd);
}
static AVCaptureSession *sc_layerSession(AVCaptureVideoPreviewLayer *self, SEL _cmd) {
    AVCaptureSession *session = objc_getAssociatedObject(self, kSCPreviewSessionKey);
    return session ?: ((id (*)(id, SEL))o_layerSession)(self, _cmd);
}
static void sc_layerSetSession(AVCaptureVideoPreviewLayer *self, SEL _cmd, AVCaptureSession *s) {
    // SwiftUI installs its preview while capture authorization is still pending.
    // Attaching an empty session through the native setter commits the Simulator
    // stub graph and emits a runtime error before the fake camera is configured.
    // Keep the preview's normal strong session ownership without that native graph.
    if (s && (SCState(s).usesFake || s.inputs.count == 0)) {
        objc_setAssociatedObject(self, kSCPreviewSessionKey, s, OBJC_ASSOCIATION_RETAIN);
        SCTrackLayer(self);
        return;
    }
    if (objc_getAssociatedObject(self, kSCPreviewSessionKey)) {
        objc_setAssociatedObject(self, kSCPreviewSessionKey, nil, OBJC_ASSOCIATION_RETAIN);
        self.contents = nil;
        if (!s) return;
    }
    ((void (*)(id, SEL, id))o_layerSetSession)(self, _cmd, s);
    SCTrackLayer(self);
}
static SC_INIT_RESULT sc_layerInitSession(SC_INIT_SELF self, SEL _cmd, AVCaptureSession *s) {
    id r = ((SCInitIMP1)o_layerInitSession)(self, _cmd, s);
    if (r) SCTrackLayer(r);
    return r;
}
static SC_INIT_RESULT sc_layerInitNoConn(SC_INIT_SELF self, SEL _cmd, AVCaptureSession *s) {
    id r = ((SCInitIMP1)o_layerInitNoConn)(self, _cmd, s);
    if (r) SCTrackLayer(r);
    return r;
}
static AVMetadataObject *sc_transformMeta(AVCaptureVideoPreviewLayer *self, SEL _cmd, AVMetadataObject *o) {
    if (![o isKindOfClass:[SCQRObject class]]) return ((id (*)(id, SEL, id))o_transformMeta)(self, _cmd, o);
    SCQRObject *q = (SCQRObject *)o;
    SCQRObject *t = class_createInstance([SCQRObject class], 0);
    CGRect b = self.bounds;
    t->_value = q->_value; t->_time = q->_time;
    t->_bounds = CGRectMake(b.origin.x + q->_bounds.origin.x * b.size.width, b.origin.y + q->_bounds.origin.y * b.size.height,
                            q->_bounds.size.width * b.size.width, q->_bounds.size.height * b.size.height);
    NSMutableArray *cs = [NSMutableArray array];
    for (NSDictionary *d in q->_corners) {
        CGPoint p; CGPointMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d, &p);
        [cs addObject:(__bridge_transfer NSDictionary *)CGPointCreateDictionaryRepresentation(
            CGPointMake(b.origin.x + p.x * b.size.width, b.origin.y + p.y * b.size.height))];
    }
    t->_corners = cs;
    return t;
}

/// Whether the app is capturing in portrait: its preview layer is taller than
/// wide, or (no layer) the connection rotates by 90/270 degrees.
static BOOL SCIsPortraitCapture(AVCaptureOutput *out) {
    AVCaptureSession *s = objc_getAssociatedObject(out, kSCSessionKey);
    [gLock lock]; NSArray *layers = gLayers.allObjects; [gLock unlock];
    for (AVCaptureVideoPreviewLayer *l in layers) {
        CGSize b = l.bounds.size;
        if (l.session == s && b.width > 0 && b.height > 0) return b.height > b.width;
    }
    return fmod(SCConnectionFor(out)->_rotation, 180) != 0;
}

/// Centre crop to a width/height ratio. Frames are upright as the preview shows
/// them, so this is the photo a real camera takes around the previewed area.
static CVPixelBufferRef SCCropToAspect(CVPixelBufferRef pb, CGFloat aspect) {
    size_t W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb);
    size_t w = W, h = H;
    if ((CGFloat)W / H > aspect) w = (size_t)llround(H * aspect); else h = (size_t)llround(W / aspect);
    if (w == W && h == H) return CVPixelBufferRetain(pb);
    CVPixelBufferRef out = SCNewBuffer(w, h);
    if (!out) return CVPixelBufferRetain(pb);
    CGFloat x = (W - w) / 2.0, y = (H - h) / 2.0;
    CIImage *ci = [[[CIImage imageWithCVPixelBuffer:pb] imageByCroppingToRect:CGRectMake(x, y, w, h)]
                   imageByApplyingTransform:CGAffineTransformMakeTranslation(-x, -y)];
    static CIContext *ctx; if (!ctx) ctx = [CIContext context];
    [ctx render:ci toCVPixelBuffer:out];
    return out;
}

static void sc_capturePhoto(AVCapturePhotoOutput *self, SEL _cmd, AVCapturePhotoSettings *settings, id<AVCapturePhotoCaptureDelegate> d) {
    if (!SCOutputIsFake(self)) { ((void (*)(id, SEL, id, id))o_capturePhoto)(self, _cmd, settings, d); return; }
    // iPhone photos are 4:3, portrait when the app captures in portrait.
    CGFloat aspect = SCIsPortraitCapture(self) ? 3.0 / 4.0 : 4.0 / 3.0;
    dispatch_async(gFrameQueue, ^{
        CVPixelBufferRef frame = gLatest ? CVPixelBufferRetain(gLatest) : SCTestPattern(gFrameCount);
        if (!frame) return;
        CVPixelBufferRef pb = SCCropToAspect(frame, aspect);
        CVPixelBufferRelease(frame);
        SCPhoto *p = class_createInstance([SCPhoto class], 0);
        p->_pixels = pb; // owned
        p->_time = CMClockGetTime(CMClockGetHostTimeClock());
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        p->_data = [[CIContext context] JPEGRepresentationOfImage:ci colorSpace:cs options:@{}];
        CGColorSpaceRelease(cs);
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([d respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)])
                [d captureOutput:self didFinishProcessingPhoto:p error:nil];
        });
    });
}

#pragma mark - Install

static IMP o_movieStart, o_movieStop, o_movieRecording;
static void sc_movieStart(AVCaptureMovieFileOutput *self, SEL cmd, NSURL *url, id<AVCaptureFileOutputRecordingDelegate> delegate) {
    if (!SCOutputIsFake(self)) { ((void (*)(id, SEL, id, id))o_movieStart)(self, cmd, url, delegate); return; }
    AVCaptureSession *session = SCSessionFor(self);
    BOOL running = SCState(session).running;
    BOOL audio = SCHasAudio(session);
    SCConnection *connection = SCConnectionFor(self);
    CGFloat rotation = connection->_rotation; BOOL mirrored = connection->_mirrored;
    NSArray *connections = self.connections;
    dispatch_async(gFrameQueue, ^{
        SCMovieRecorder *previous = objc_getAssociatedObject(self, kSCMovieKey);
        if (previous && !previous.finished) return; // Native API requires stop/finish before another start.
        SCMovieRecorder *recorder = [[SCMovieRecorder alloc] initWithOutput:self URL:url delegate:delegate connections:connections audio:audio rotation:rotation mirrored:mirrored queue:gFrameQueue];
        objc_setAssociatedObject(self, kSCMovieKey, recorder, OBJC_ASSOCIATION_RETAIN);
        [recorder start];
        if (!running) [recorder stop];
    });
}
static void sc_movieStop(AVCaptureMovieFileOutput *self, SEL cmd) {
    if (!SCOutputIsFake(self) && !objc_getAssociatedObject(self, kSCMovieKey)) { ((void (*)(id, SEL))o_movieStop)(self, cmd); return; }
    dispatch_async(gFrameQueue, ^{ [objc_getAssociatedObject(self, kSCMovieKey) stop]; });
}
static BOOL sc_movieRecording(AVCaptureMovieFileOutput *self, SEL cmd) {
    SCMovieRecorder *recorder = objc_getAssociatedObject(self, kSCMovieKey);
    if (SCOutputIsFake(self) || recorder) return recorder.isRecording;
    return ((BOOL (*)(id, SEL))o_movieRecording)(self, cmd);
}

__attribute__((constructor)) static void SCInstall(void) {
    if (getenv("SIMCAM_DISABLE")) return;
    gLock = [NSLock new];
    gRunning = [NSHashTable weakObjectsHashTable];
    gLayers = [NSHashTable weakObjectsHashTable];
    gFrameQueue = dispatch_queue_create("com.dautov.SimulatorCamera.frames", DISPATCH_QUEUE_SERIAL);
    gQR = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil options:@{ CIDetectorAccuracy: CIDetectorAccuracyHigh }];
    SCInstallFakeDealloc();

    Class D = [AVCaptureDevice class];
    SCSwizzleClass(D, @selector(defaultDeviceWithMediaType:), (IMP)sc_defaultDevice, &o_defaultDevice);
    SCSwizzleClass(D, @selector(defaultDeviceWithDeviceType:mediaType:position:), (IMP)sc_defaultDeviceType, &o_defaultDeviceType);
    SCSwizzleClass(D, @selector(devicesWithMediaType:), (IMP)sc_devicesWithMediaType, &o_devicesWithMediaType);
    SCSwizzleClass(D, @selector(devices), (IMP)sc_devices, &o_devices);
    SCSwizzleClass(D, @selector(deviceWithUniqueID:), (IMP)sc_deviceWithUniqueID, &o_deviceWithUniqueID);
    SCSwizzleInstance([AVCaptureDeviceDiscoverySession class], @selector(devices), (IMP)sc_discoveryDevices, &o_discoveryDevices);

    Class I = [AVCaptureDeviceInput class];
    SCSwizzleInstance(I, @selector(initWithDevice:error:), (IMP)sc_inputInit, &o_inputInit);
    SCSwizzleClass(I, @selector(deviceInputWithDevice:error:), (IMP)sc_inputFactory, &o_inputFactory);

    Class S = [AVCaptureSession class];
    SCSwizzleInstance(S, @selector(canAddInput:), (IMP)sc_canAddInput, &o_canAddInput);
    SCSwizzleInstance(S, @selector(addInput:), (IMP)sc_addInput, &o_addInput);
    SCSwizzleInstance(S, @selector(removeInput:), (IMP)sc_removeInput, &o_removeInput);
    SCSwizzleInstance(S, @selector(inputs), (IMP)sc_inputs, &o_inputs);
    SCSwizzleInstance(S, @selector(outputs), (IMP)sc_outputs, &o_outputs);
    SCSwizzleInstance(S, @selector(canAddOutput:), (IMP)sc_canAddOutput, &o_canAddOutput);
    SCSwizzleInstance(S, @selector(addOutput:), (IMP)sc_addOutput, &o_addOutput);
    SCSwizzleInstance(S, @selector(removeOutput:), (IMP)sc_removeOutput, &o_removeOutput);
    SCSwizzleInstance(S, @selector(startRunning), (IMP)sc_startRunning, &o_startRunning);
    SCSwizzleInstance(S, @selector(stopRunning), (IMP)sc_stopRunning, &o_stopRunning);
    SCSwizzleInstance(S, @selector(isRunning), (IMP)sc_isRunning, &o_isRunning);
    SCSwizzleInstance(S, @selector(beginConfiguration), (IMP)sc_beginConfig, &o_beginConfig);
    SCSwizzleInstance(S, @selector(commitConfiguration), (IMP)sc_commitConfig, &o_commitConfig);

    Class O = [AVCaptureOutput class];
    SCSwizzleInstance(O, @selector(connectionWithMediaType:), (IMP)sc_connectionWithMediaType, &o_connectionWithMediaType);
    SCSwizzleInstance(O, @selector(connections), (IMP)sc_connections, &o_connections);
    Class M = [AVCaptureMetadataOutput class];
    SCSwizzleInstance(M, @selector(setMetadataObjectTypes:), (IMP)sc_setMetaTypes, &o_setMetaTypes);
    SCSwizzleInstance(M, @selector(metadataObjectTypes), (IMP)sc_metaTypes, &o_metaTypes);
    SCSwizzleInstance(M, @selector(availableMetadataObjectTypes), (IMP)sc_availableMetaTypes, &o_availableMetaTypes);
    SCSwizzleInstance(M, @selector(setRectOfInterest:), (IMP)sc_setRectOfInterest, &o_setRectOfInterest);
    SCSwizzleInstance(M, @selector(rectOfInterest), (IMP)sc_rectOfInterest, &o_rectOfInterest);
    SCSwizzleInstance([AVCapturePhotoOutput class], @selector(capturePhotoWithSettings:delegate:), (IMP)sc_capturePhoto, &o_capturePhoto);
    Class F = [AVCaptureMovieFileOutput class];
    SCSwizzleInstance(F, @selector(startRecordingToOutputFileURL:recordingDelegate:), (IMP)sc_movieStart, &o_movieStart);
    SCSwizzleInstance(F, @selector(stopRecording), (IMP)sc_movieStop, &o_movieStop);
    SCSwizzleInstance(F, @selector(isRecording), (IMP)sc_movieRecording, &o_movieRecording);

    Class L = [AVCaptureVideoPreviewLayer class];
    SCSwizzleInstance(L, @selector(session), (IMP)sc_layerSession, &o_layerSession);
    SCSwizzleInstance(L, @selector(connection), (IMP)sc_layerConnection, &o_layerConnection);
    SCSwizzleInstance(L, @selector(setSession:), (IMP)sc_layerSetSession, &o_layerSetSession);
    SCSwizzleInstance(L, @selector(initWithSession:), (IMP)sc_layerInitSession, &o_layerInitSession);
    SCSwizzleInstance(L, @selector(initWithSessionWithNoConnection:), (IMP)sc_layerInitNoConn, &o_layerInitNoConn);
    SCSwizzleInstance(L, @selector(transformedMetadataObjectForMetadataObject:), (IMP)sc_transformMeta, &o_transformMeta);

    SCLog(@"camera injected (frames: %s, or the built-in test pattern)", SC_FRAME_STORE_PATH);
}
