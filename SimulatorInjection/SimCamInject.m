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
//  Without the Mac app running, a built-in animated test pattern is shown.
//
//  Simulator only. Build: SimulatorInjection/build.sh

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/mman.h>
#import <fcntl.h>
#import <stdatomic.h>
#import "SCFrameStore.h"

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
}
- (NSArray *)inputPorts { return @[]; }
- (AVMediaType)mediaType { return AVMediaTypeVideo; } // private, read by AVCaptureSession internals
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
- (void)dealloc { if (_pixels) CVPixelBufferRelease(_pixels); }
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

#pragma mark - Frame source (Mac app frame file, or built-in test pattern)

static uint8_t *gStore;           // mmap of SC_FRAME_STORE_PATH, read-only
static uint64_t gLastSeq;
static CVPixelBufferRef gLatest;  // newest delivered frame (Mac or pattern), owned
static CVPixelBufferRef gStoreLatest; // newest complete frame from the Mac app, owned
static double gStoreLatestAt;     // when gStoreLatest was read (seconds since 1970)
static uint64_t gFrameCount;
static dispatch_queue_t gFrameQueue;

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
    uint32_t w = h->width, ht = h->height, bpr = h->bytesPerRow;
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

@interface SCSessionState : NSObject
@property (nonatomic) BOOL usesFake;
@property (nonatomic) BOOL running;
@property (nonatomic, strong) NSMutableArray *inputs;
@property (nonatomic, strong) NSHashTable *outputs;   // weak
@end
@implementation SCSessionState
- (instancetype)init { if ((self = [super init])) { _inputs = [NSMutableArray array]; _outputs = [NSHashTable weakObjectsHashTable]; } return self; }
@end

static const void *kSCStateKey = &kSCStateKey;
static const void *kSCSessionKey = &kSCSessionKey;        // output/layer -> session (weak box)
static const void *kSCConnKey = &kSCConnKey;              // output/layer -> SCConnection
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

static SCConnection *SCConnectionFor(id obj) {
    SCConnection *c = objc_getAssociatedObject(obj, kSCConnKey);
    if (!c) { c = SCNewConnection(); objc_setAssociatedObject(obj, kSCConnKey, c, OBJC_ASSOCIATION_RETAIN); }
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
    gFrameCount++;
    CVPixelBufferRef pb = SCReadStore();
    if (!pb) pb = SCTestPattern(gFrameCount);
    if (!pb) return;
    if (gLatest) CVPixelBufferRelease(gLatest);
    gLatest = CVPixelBufferRetain(pb);
    CMTime pts = CMClockGetTime(CMClockGetHostTimeClock());

    [gLock lock];
    NSArray *sessions = gRunning.allObjects;
    NSArray *layers = gLayers.allObjects;
    [gLock unlock];

    for (AVCaptureSession *s in sessions) {
        for (AVCaptureOutput *out in SCState(s).outputs.allObjects) {
            if ([out isKindOfClass:[AVCaptureVideoDataOutput class]]) {
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
        CGImageRef img = [ctx createCGImage:ci fromRect:ci.extent];
        dispatch_async(dispatch_get_main_queue(), ^{
            [CATransaction begin];
            [CATransaction setDisableActions:YES]; // no cross-fade between frames
            for (AVCaptureVideoPreviewLayer *l in layers) {
                AVCaptureSession *s = l.session;
                if (!s || !SCState(s).running) continue;
                NSString *g = l.videoGravity;
                l.contentsGravity = [g isEqualToString:AVLayerVideoGravityResize] ? kCAGravityResize
                                  : [g isEqualToString:AVLayerVideoGravityResizeAspect] ? kCAGravityResizeAspect
                                  : kCAGravityResizeAspectFill;
                l.contents = (__bridge id)img;
            }
            [CATransaction commit];
            CGImageRelease(img);
        });
    }
    CVPixelBufferRelease(pb);
}

static void SCUpdateTimer(void) {
    [gLock lock];
    BOOL any = gRunning.count > 0;
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
static id sc_inputInit(id self, SEL _cmd, AVCaptureDevice *d, NSError **e) {
    if ([d isKindOfClass:[SCDevice class]]) return SCMakeInput(d);
    return ((id (*)(id, SEL, AVCaptureDevice *, NSError **))o_inputInit)(self, _cmd, d, e);
}
static id sc_inputFactory(id self, SEL _cmd, AVCaptureDevice *d, NSError **e) {
    if ([d isKindOfClass:[SCDevice class]]) return SCMakeInput(d);
    return ((id (*)(id, SEL, AVCaptureDevice *, NSError **))o_inputFactory)(self, _cmd, d, e);
}

#pragma mark - AVCaptureSession

static IMP o_canAddInput, o_addInput, o_removeInput, o_inputs, o_addOutput, o_removeOutput,
           o_startRunning, o_stopRunning, o_isRunning, o_canAddOutput, o_addInputNoConn;

static BOOL sc_canAddInput(AVCaptureSession *self, SEL _cmd, AVCaptureInput *in) {
    if ([in isKindOfClass:[SCDeviceInput class]]) return YES;
    return ((BOOL (*)(id, SEL, id))o_canAddInput)(self, _cmd, in);
}
static void sc_addInput(AVCaptureSession *self, SEL _cmd, AVCaptureInput *in) {
    if ([in isKindOfClass:[SCDeviceInput class]]) {
        SCSessionState *st = SCState(self);
        if (![st.inputs containsObject:in]) [st.inputs addObject:in];
        st.usesFake = YES;
        return;
    }
    ((void (*)(id, SEL, id))o_addInput)(self, _cmd, in);
}
static void sc_removeInput(AVCaptureSession *self, SEL _cmd, AVCaptureInput *in) {
    if ([in isKindOfClass:[SCDeviceInput class]]) {
        SCSessionState *st = SCState(self);
        [st.inputs removeObject:in];
        st.usesFake = st.inputs.count > 0;
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
    BOOL ok = ((BOOL (*)(id, SEL, id))o_canAddOutput)(self, _cmd, o);
    return ok || SCState(self).usesFake;
}
static void sc_addOutput(AVCaptureSession *self, SEL _cmd, AVCaptureOutput *o) {
    [SCState(self).outputs addObject:o];
    objc_setAssociatedObject(o, kSCSessionKey, self, OBJC_ASSOCIATION_ASSIGN);
    @try { ((void (*)(id, SEL, id))o_addOutput)(self, _cmd, o); }
    @catch (NSException *ex) { SCLog(@"addOutput fallback (%@)", ex.reason); }
}
static void sc_removeOutput(AVCaptureSession *self, SEL _cmd, AVCaptureOutput *o) {
    [SCState(self).outputs removeObject:o];
    @try { ((void (*)(id, SEL, id))o_removeOutput)(self, _cmd, o); } @catch (NSException *ex) {}
}
static void sc_startRunning(AVCaptureSession *self, SEL _cmd) {
    SCSessionState *st = SCState(self);
    if (!st.usesFake) { ((void (*)(id, SEL))o_startRunning)(self, _cmd); return; }
    if (st.running) return;
    st.running = YES;
    [gLock lock]; [gRunning addObject:self]; [gLock unlock];
    SCUpdateTimer();
    SCLog(@"session running with the injected camera");
    [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionDidStartRunningNotification object:self];
}
static void sc_stopRunning(AVCaptureSession *self, SEL _cmd) {
    SCSessionState *st = SCState(self);
    if (!st.usesFake) { ((void (*)(id, SEL))o_stopRunning)(self, _cmd); return; }
    if (!st.running) return;
    st.running = NO;
    [gLock lock]; [gRunning removeObject:self]; [gLock unlock];
    SCUpdateTimer();
    [[NSNotificationCenter defaultCenter] postNotificationName:AVCaptureSessionDidStopRunningNotification object:self];
}
static IMP o_beginConfig, o_commitConfig;
// A session on the injected camera has no real graph to configure; the stock
// commit walks output connections and would hit the fake ones.
static void sc_beginConfig(AVCaptureSession *self, SEL _cmd) {
    SCSessionState *st = objc_getAssociatedObject(self, kSCStateKey);
    if (st.usesFake) return;
    ((void (*)(id, SEL))o_beginConfig)(self, _cmd);
}
static void sc_commitConfig(AVCaptureSession *self, SEL _cmd) {
    SCSessionState *st = objc_getAssociatedObject(self, kSCStateKey);
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
           o_layerConnection, o_layerSetSession, o_layerInitSession, o_layerInitNoConn, o_transformMeta,
           o_capturePhoto, o_setRectOfInterest, o_rectOfInterest;

static BOOL SCOutputIsFake(id out) {
    AVCaptureSession *s = objc_getAssociatedObject(out, kSCSessionKey);
    SCSessionState *st = s ? objc_getAssociatedObject(s, kSCStateKey) : nil;
    return st.usesFake;
}
static AVCaptureConnection *sc_connectionWithMediaType(AVCaptureOutput *self, SEL _cmd, AVMediaType t) {
    if (SCOutputIsFake(self)) return SCConnectionFor(self);
    return ((id (*)(id, SEL, id))o_connectionWithMediaType)(self, _cmd, t);
}
static NSArray *sc_connections(AVCaptureOutput *self, SEL _cmd) {
    if (SCOutputIsFake(self)) return @[SCConnectionFor(self)];
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
    if (st.usesFake) return SCConnectionFor(self);
    return ((id (*)(id, SEL))o_layerConnection)(self, _cmd);
}
static void sc_layerSetSession(AVCaptureVideoPreviewLayer *self, SEL _cmd, AVCaptureSession *s) {
    ((void (*)(id, SEL, id))o_layerSetSession)(self, _cmd, s);
    SCTrackLayer(self);
}
static id sc_layerInitSession(AVCaptureVideoPreviewLayer *self, SEL _cmd, AVCaptureSession *s) {
    id r = ((id (*)(id, SEL, id))o_layerInitSession)(self, _cmd, s);
    if (r) SCTrackLayer(r);
    return r;
}
static id sc_layerInitNoConn(AVCaptureVideoPreviewLayer *self, SEL _cmd, AVCaptureSession *s) {
    id r = ((id (*)(id, SEL, id))o_layerInitNoConn)(self, _cmd, s);
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

static void sc_capturePhoto(AVCapturePhotoOutput *self, SEL _cmd, AVCapturePhotoSettings *settings, id<AVCapturePhotoCaptureDelegate> d) {
    if (!SCOutputIsFake(self)) { ((void (*)(id, SEL, id, id))o_capturePhoto)(self, _cmd, settings, d); return; }
    dispatch_async(gFrameQueue, ^{
        CVPixelBufferRef pb = gLatest ? CVPixelBufferRetain(gLatest) : SCTestPattern(gFrameCount);
        if (!pb) return;
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

__attribute__((constructor)) static void SCInstall(void) {
    if (getenv("SIMCAM_DISABLE")) return;
    gLock = [NSLock new];
    gRunning = [NSHashTable weakObjectsHashTable];
    gLayers = [NSHashTable weakObjectsHashTable];
    gFrameQueue = dispatch_queue_create("com.dautov.SimulatorCamera.frames", DISPATCH_QUEUE_SERIAL);
    gQR = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil options:@{ CIDetectorAccuracy: CIDetectorAccuracyHigh }];

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

    Class L = [AVCaptureVideoPreviewLayer class];
    SCSwizzleInstance(L, @selector(connection), (IMP)sc_layerConnection, &o_layerConnection);
    SCSwizzleInstance(L, @selector(setSession:), (IMP)sc_layerSetSession, &o_layerSetSession);
    SCSwizzleInstance(L, @selector(initWithSession:), (IMP)sc_layerInitSession, &o_layerInitSession);
    SCSwizzleInstance(L, @selector(initWithSessionWithNoConnection:), (IMP)sc_layerInitNoConn, &o_layerInitNoConn);
    SCSwizzleInstance(L, @selector(transformedMetadataObjectForMetadataObject:), (IMP)sc_transformMeta, &o_transformMeta);

    SCLog(@"camera injected (frames: %s, or the built-in test pattern)", SC_FRAME_STORE_PATH);
}
