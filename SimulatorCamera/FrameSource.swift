//
//  FrameSource.swift
//  SimulatorCamera
//
//  Common shape for everything that produces frames in the container app:
//  Mac camera, video file, static image, QR generator. SourceManager owns
//  the active one and pumps its frames into CameraLink.
//
//  Every source hands the manager a canonical 1280x720 BGRA, IOSurface-
//  backed CVPixelBuffer; the FrameNormalizer below does the letterboxing /
//  rotation / format conversion once, with a reusable CIContext and
//  pixel-buffer pool, instead of each source improvising its own conversion.
//

import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo

protocol FrameSource: AnyObject {
    /// Kind reported to the extension.
    var kind: SimCamSourceKind { get }

    /// Start producing frames. Throw if hardware/file fails to open.
    func start() async throws

    /// Stop producing frames. Idempotent.
    func stop()

    /// Hook the SourceManager registers. Called on a background queue with
    /// a canonical pixel buffer.
    var onFrame: ((CVPixelBuffer) -> Void)? { get set }
}

/// Errors a source can throw on start.
enum FrameSourceError: LocalizedError {
    case noDevice
    case permissionDenied
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .noDevice: return "No camera device found."
        case .permissionDenied: return "Camera access denied. Grant access in System Settings → Privacy & Security → Camera."
        case .invalidInput(let m): return m
        }
    }
}

/// Converts arbitrary pixel buffers into canonical ones.
///
/// Thread-safety: one instance per source; sources call it from a single
/// capture / decode thread. CIContext and CVPixelBufferPool are themselves
/// thread-safe, so sharing an instance across threads is also fine.
final class FrameNormalizer {

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pool = FrameRaster.makePool()
    private let canonicalExtent = CGRect(
        x: 0, y: 0,
        width: kSimCamFrameWidth, height: kSimCamFrameHeight
    )

    /// Return a canonical pixel buffer for `pixelBuffer`. `transform` is
    /// applied first (video preferredTransform); the result is aspect-fit
    /// onto a black canonical canvas. Already-canonical BGRA buffers are
    /// returned as-is (zero copy).
    func canonicalize(
        _ pixelBuffer: CVPixelBuffer,
        transform: CGAffineTransform = .identity
    ) -> CVPixelBuffer? {
        if transform.isIdentity, SimCamFrameCheck.problem(with: pixelBuffer) == nil {
            return pixelBuffer
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if !transform.isIdentity {
            image = image.transformed(by: transform)
            // Move the rotated image back to the origin.
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.origin.x,
                y: -image.extent.origin.y
            ))
        }

        let fit = FrameRaster.aspectFitRect(for: image.extent.size)
        let scale = fit.width / max(image.extent.width, 1)
        image = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: fit.origin.x, y: fit.origin.y))

        guard let dst = dequeue() else { return nil }
        // Clear to black first so letterbox bars are deterministic.
        context.render(
            CIImage(color: .black).cropped(to: canonicalExtent),
            to: dst,
            bounds: canonicalExtent,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        context.render(
            image.cropped(to: canonicalExtent),
            to: dst,
            bounds: canonicalExtent,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return dst
    }

    private func dequeue() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        return status == kCVReturnSuccess ? pb : nil
    }
}
