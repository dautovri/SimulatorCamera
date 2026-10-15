//
//  QRSource.swift
//  SimulatorCamera
//
//  Programmatic QR code source. Renders the supplied string as a QR code
//  on a canonical white pixel buffer and re-enqueues it at the canonical
//  rate. Useful for testing QR scanners + payment scanners without holding
//  a phone up to a screen.
//

import Foundation
import CoreVideo
import OSLog

final class QRSource: FrameSource {

    let kind: SimCamSourceKind = .qrCode
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let payload: String
    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "qr")
    private var task: Task<Void, Never>?

    init(payload: String) {
        self.payload = payload
    }

    func start() async throws {
        task?.cancel()
        let payload = self.payload
        let frame = try await Task.detached(priority: .userInitiated) {
            guard let frame = QRRenderer.render(payload: payload) else {
                throw FrameSourceError.invalidInput("Could not render a QR code for that payload (too long?).")
            }
            return frame
        }.value
        log.info("Rendered QR for payload (length=\(payload.count))")
        task = Task.detached(priority: .userInitiated) { [self] in
            await self.tickLoop(frame)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        onFrame = nil
    }

    private func tickLoop(_ frame: CVPixelBuffer) async {
        let interval = Duration.seconds(1.0 / Double(kSimCamFrameRate))
        var next = ContinuousClock.now
        while !Task.isCancelled {
            onFrame?(frame)
            next += interval
            try? await Task.sleep(until: next, clock: .continuous)
        }
    }
}
