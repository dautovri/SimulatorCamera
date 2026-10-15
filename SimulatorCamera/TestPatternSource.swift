//
//  TestPatternSource.swift
//  SimulatorCamera
//
//  Container-side test pattern. The camera extension draws its own pattern for
//  macOS apps; this one feeds iOS Simulator apps (via FrameStore) so they get
//  frames as soon as the Mac app is open, before any source is picked.
//

import CoreGraphics
import Foundation

final class TestPatternSource: FrameSource, @unchecked Sendable {
    let kind: SimCamSourceKind = .testPattern
    var onFrame: ((SimCamFrame) -> Void)?

    private let width = 1280, height = 720
    private var timer: DispatchSourceTimer?
    private var tick = 0

    func start() async throws {
        stop()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.dautov.SimulatorCamera.pattern"))
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.emit() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func emit() {
        let rowBytes = width * 4
        var data = Data(count: rowBytes * height)
        let t = tick
        tick += 1
        data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
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
        onFrame?(SimCamFrame(width: width, height: height, bytesPerRow: rowBytes,
                             timestampSeconds: Date().timeIntervalSince1970, bgraData: data))
    }
}
