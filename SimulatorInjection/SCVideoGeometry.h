#pragma once
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

// Source metadata belongs to the copied frame, including cached/repeated frames.
#define SCFrameSourceKindKey CFSTR("SimulatorCamera.SourceKind")

static inline CGFloat SCFramePortraitRotation(CVPixelBufferRef pixels) {
    CFNumberRef kind = (CFNumberRef)CVBufferCopyAttachment(pixels, SCFrameSourceKindKey, NULL);
    int value = 0;
    if (kind && CFGetTypeID(kind) == CFNumberGetTypeID()) CFNumberGetValue(kind, kCFNumberIntType, &value);
    if (kind) CFRelease(kind);
    // SimCamSourceKind.macCamera = 1. Host webcam pixels are already upright.
    // Treat that image as the emulated camera's portrait (90°) view, rather
    // than pretending it is an unrotated iPhone sensor image. Other sources
    // retain their existing sensor-coordinate contract.
    return value == 1 ? 90 : 0;
}

// Top-left image/display coordinates. The source-to-sensor normalization and
// requested connection rotation compose here; no pixels need resampling for MOV.
static inline CGAffineTransform SCVideoDisplayTransform(CGSize size, CGFloat requestedRotation,
                                                       BOOL mirrored, CGFloat portraitRotation) {
    CGAffineTransform transform = CGAffineTransformMakeRotation((requestedRotation - portraitRotation) * M_PI / 180.0);
    // Mirror about the displayed image's vertical axis, after rotation.
    if (mirrored) { transform.a = -transform.a; transform.c = -transform.c; }
    CGRect bounds = CGRectApplyAffineTransform((CGRect){CGPointZero, size}, transform);
    transform.tx -= bounds.origin.x; transform.ty -= bounds.origin.y;
    return transform;
}
