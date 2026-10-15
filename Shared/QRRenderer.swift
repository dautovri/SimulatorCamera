//
//  QRRenderer.swift
//  SimulatorCamera shared
//
//  Renders a QR payload onto a canonical white frame. Used by the QR
//  source in the container app and by simcamctl.
//

import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

public enum QRRenderer {
    public static let qrSide: CGFloat = 600

    /// Nil when Core Image cannot encode the payload (empty or too long).
    public static func render(payload: String) -> CVPixelBuffer? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let base = filter.outputImage, base.extent.width > 0, base.extent.height > 0 else {
            return nil
        }
        let scaled = base.transformed(by: CGAffineTransform(
            scaleX: qrSide / base.extent.width,
            y: qrSide / base.extent.height
        ))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let qrCG = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return FrameRaster.render(background: CGColor(red: 1, green: 1, blue: 1, alpha: 1)) { ctx in
            let rect = CGRect(
                x: (CGFloat(kSimCamFrameWidth) - qrSide) / 2,
                y: (CGFloat(kSimCamFrameHeight) - qrSide) / 2,
                width: qrSide, height: qrSide
            )
            ctx.interpolationQuality = .none
            ctx.draw(qrCG, in: rect)
        }
    }
}
