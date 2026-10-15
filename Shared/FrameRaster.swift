//
//  FrameRaster.swift
//  SimulatorCamera shared
//
//  CPU rasterizer for the static sources (image, QR) and simcamctl: draws
//  straight into an IOSurface-backed canonical 1280x720 BGRA pixel buffer
//  that can be enqueued on the extension's sink stream without a copy.
//

import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo

public enum FrameRaster {

    public static var bytesPerRow: Int { kSimCamFrameWidth * kSimCamBytesPerPixel }

    /// Aspect-fit `size` inside the canonical frame, centered.
    public static func aspectFitRect(for size: CGSize) -> CGRect {
        aspectFitRect(for: size, in: CGSize(width: kSimCamFrameWidth, height: kSimCamFrameHeight))
    }

    public static func aspectFitRect(for size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// Pixel-buffer attributes every canonical buffer is created with.
    public static var pixelBufferAttributes: [CFString: Any] {
        [
            kCVPixelBufferWidthKey: kSimCamFrameWidth,
            kCVPixelBufferHeightKey: kSimCamFrameHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
    }

    /// A fresh, IOSurface-backed canonical pixel buffer.
    public static func makePixelBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            kSimCamFrameWidth,
            kSimCamFrameHeight,
            kCVPixelFormatType_32BGRA,
            pixelBufferAttributes as CFDictionary,
            &pb
        )
        return status == kCVReturnSuccess ? pb : nil
    }

    /// A pool of canonical pixel buffers for sources that emit continuously.
    public static func makePool() -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes as CFDictionary, &pool)
        return pool
    }

    /// Render a canonical frame. `draw` receives a context already filled
    /// with `background`; origin is bottom-left (CoreGraphics).
    public static func render(
        background: CGColor,
        draw: (CGContext) -> Void
    ) -> CVPixelBuffer? {
        guard let pb = makePixelBuffer() else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base,
            width: kSimCamFrameWidth,
            height: kSimCamFrameHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: kSimCamFrameWidth, height: kSimCamFrameHeight))
        draw(ctx)
        return pb
    }

    /// Aspect-fit `image` on `background` into a canonical pixel buffer.
    public static func render(image: CGImage, background: CGColor) -> CVPixelBuffer? {
        render(background: background) { ctx in
            let rect = aspectFitRect(for: CGSize(width: image.width, height: image.height))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: rect)
        }
    }

    /// Wrap a canonical pixel buffer in a host-clock-stamped CMSampleBuffer,
    /// the shape the sink stream expects. `formatDescription` is created
    /// from the buffer so it always matches.
    public static func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else {
            return nil
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(kSimCamFrameRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr else {
            return nil
        }
        return sample
    }
}
