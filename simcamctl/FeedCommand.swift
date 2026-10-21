//
//  FeedCommand.swift
//  simcamctl
//
//  `simcamctl feed …` publishes frames straight to the simulator frame file
//  (FrameStore) at 30 fps, without the Mac app or the camera extension.
//  Simulator apps launched with SimulatorInjection's library show them.
//  Runs until interrupted (Ctrl-C) or for --seconds N.
//

import AVFoundation
import CoreImage
import Foundation
import os

final class FeedCommand: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Source {
        case pattern
        case qr(String)
        case image(String)
        case camera
    }

    private let store = FrameStore()
    private let width = 1280, height = 720
    private var still: CVPixelBuffer?
    private var tick = 0
    private var session: AVCaptureSession?
    // Bumped from the capture queue, read from the feed timer queue.
    private let written = OSAllocatedUnfairLock(initialState: 0)
    private var parentWatch: DispatchSourceRead?

    func run(_ source: Source, seconds: Double?) -> Never {
        if ProcessInfo.processInfo.environment["SIMCAM_STOP_ON_STDIN_EOF"] == "1" {
            let watch = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global())
            watch.setEventHandler { [self] in
                var byte: UInt8 = 0
                if read(STDIN_FILENO, &byte, 1) == 0 { finish() }
            }
            parentWatch = watch
            watch.resume()
        }
        switch source {
        case .pattern: break
        case .qr(let text): still = render(qr: text)
        case .image(let path): still = render(imageAt: path)
        case .camera: startCamera()
        }
        if case .qr = source, still == nil { fail("could not render the QR code") }
        if case .image = source, still == nil { fail("could not read the image") }

        let started = Date()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "feed"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [self] in
            if let seconds, Date().timeIntervalSince(started) > seconds { finish() }
            switch source {
            case .camera: break // frames arrive from the capture delegate
            case .pattern: write(pattern())
            case .qr, .image: if let still { write(still) }
            }
            if tick % 150 == 0 { print("feeding \(store.description(written: written.withLock { $0 }))"); fflush(stdout) }
            tick += 1
        }
        timer.resume()
        signal(SIGINT) { _ in exit(0) }
        print("simcamctl: feeding \(FrameStore.path) — launch simulator apps with SimulatorInjection")
        dispatchMain()
    }

    private func finish() -> Never {
        print("done: \(written.withLock { $0 }) frames")
        exit(0)
    }

    /// Runtime failures exit 1 (generic error); exit 3 is reserved for invalid
    /// arguments, which main.swift reports before a feed ever starts.
    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }

    private func write(_ pb: CVPixelBuffer, sourceKind: UInt32 = 0) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        store.write(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pb), bgra: base, sourceKind: sourceKind,
                    time: Date().timeIntervalSince1970)
        written.withLock { $0 += 1 }
    }

    // MARK: Sources

    private func newBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        return pb
    }

    private func withContext(_ pb: CVPixelBuffer, _ draw: (CGContext) -> Void) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        draw(ctx)
    }

    private func pattern() -> CVPixelBuffer {
        let pb = newBuffer()!
        let t = tick
        withContext(pb) { ctx in
            let bars: [(CGFloat, CGFloat, CGFloat)] = [(0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75), (0, 0.75, 0),
                                                        (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75)]
            let w = CGFloat(width) / 7
            for (i, c) in bars.enumerated() {
                ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
                ctx.fill(CGRect(x: CGFloat(i) * w, y: 0, width: w + 1, height: CGFloat(height)))
            }
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.9)
            ctx.fill(CGRect(x: CGFloat((t * 8) % width), y: 0, width: 24, height: CGFloat(height)))
        }
        return pb
    }

    private func render(qr text: String) -> CVPixelBuffer? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(text.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let qr = filter?.outputImage, let pb = newBuffer() else { return nil }
        let side = 600.0
        let scaled = qr.transformed(by: CGAffineTransform(scaleX: side / qr.extent.width, y: side / qr.extent.height))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        withContext(pb) { ctx in
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: (Double(width) - side) / 2, y: (Double(height) - side) / 2, width: side, height: side))
        }
        return pb
    }

    private func render(imageAt path: String) -> CVPixelBuffer? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil), let pb = newBuffer() else { return nil }
        withContext(pb) { ctx in
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let s = min(Double(width) / Double(img.width), Double(height) / Double(img.height))
            let w = Double(img.width) * s, h = Double(img.height) * s
            ctx.draw(img, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
        }
        return pb
    }

    /// Camera capture delivers no frames — and no error — without TCC consent,
    /// so resolve the authorization up front and fail loudly instead.
    private func requireCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let answered = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .video) { _ in answered.signal() }
            // An unattended run (script, CI, ssh into a logged-in Mac) would
            // otherwise wait forever on a prompt nobody sees.
            if answered.wait(timeout: .now() + Self.promptTimeout) == .timedOut {
                fail("timed out waiting for the camera permission prompt. Answer it on the Mac's screen, or allow your terminal app in System Settings → Privacy & Security → Camera, then run this command again.")
            }
            if AVCaptureDevice.authorizationStatus(for: .video) != .authorized { fail(Self.cameraDeniedMessage) }
        case .restricted:
            fail("camera access is restricted by a system policy (Screen Time or a configuration profile) and cannot be granted from System Settings.")
        default:
            fail(Self.cameraDeniedMessage)
        }
    }

    private static let promptTimeout: DispatchTimeInterval = .seconds(60)

    private static let cameraDeniedMessage = """
        camera access denied. Allow your terminal app (Terminal, iTerm, Warp, …) in \
        System Settings → Privacy & Security → Camera, then run this command again. \
        Alternatively pick "Mac Camera" in the SimulatorCamera app.
        """

    private func startCamera() {
        // Look for hardware first so a Mac without a camera says so, instead
        // of asking for (or complaining about) a permission it can't use.
        guard let device = AVCaptureDevice.default(for: .video) else { fail("no Mac camera available") }
        requireCameraAccess()
        guard let input = try? AVCaptureDeviceInput(device: device) else { fail("could not open the Mac camera \(device.localizedName)") }
        let s = AVCaptureSession()
        s.sessionPreset = .hd1280x720
        s.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera"))
        s.addOutput(out)
        s.startRunning()
        session = s
        print("using Mac camera: \(device.localizedName)")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) { write(pb, sourceKind: UInt32(SimCamSourceKind.macCamera.rawValue)) }
    }
}

extension FrameStore {
    func description(written: Int) -> String { "\(written) frames written" }
}
