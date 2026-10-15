//
//  SimCamCLIClient.swift
//  simcamctl
//
//  Command implementations. Talks to the running camera extension through
//  CoreMediaIO: custom properties for control/status, the sink stream for
//  one-shot frame pushes. Every command exits with a documented code.
//

import Foundation
import AppKit
import CoreVideo

final class SimCamCLIClient {

    private let client = CMIOSinkClient()

    private func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(code)
    }

    /// Locate the virtual camera or exit 2 with a hint.
    private func attach() {
        do {
            try client.attach()
        } catch {
            fail("\(error.localizedDescription) Run /Applications/SimulatorCamera.app and click Activate.", code: 2)
        }
    }

    // MARK: - Subcommands

    func runPing() {
        attach()
        do {
            let status = try client.readStatus()
            print("extension reachable: \"\(kSimCamDeviceName)\" source=\(status.activeSourceKind.label) streaming=\(status.isStreamRunning ? "yes" : "no")")
        } catch {
            fail("device found but status property unreadable: \(error.localizedDescription)", code: 2)
        }
        exit(0)
    }

    func runStatus() {
        attach()
        let status: SimCamStatus
        do {
            status = try client.readStatus()
        } catch {
            fail(error.localizedDescription, code: 2)
        }
        print("active source:     \(status.activeSourceKind.label)")
        print("connected clients: \(status.connectedClientCount)")
        print("stream running:    \(status.isStreamRunning ? "yes" : "no")")
        print("sink open:         \(status.isSinkOpen ? "yes" : "no")")
        print("last frame ts:     \(String(format: "%.3f", status.lastFrameTimestampSeconds))s")
        print("frames received:   \(status.framesReceived)")
        print("frames rejected:   \(status.framesRejected)")
        exit(0)
    }

    func runSetSource(_ kind: SimCamSourceKind) {
        attach()
        do {
            try client.setSourceKind(kind)
        } catch {
            fail("setSource failed: \(error.localizedDescription)", code: 1)
        }
        print("source switched to \(kind.label)")
        exit(0)
    }

    func runSetQR(payload: String) {
        guard !payload.isEmpty else { fail("empty QR payload", code: 3) }
        guard let frame = QRRenderer.render(payload: payload) else {
            fail("could not render a QR code for that payload (too long?)", code: 1)
        }
        pushSingleFrame(frame, kind: .qrCode, description: "QR pushed (\(payload.count) chars)")
    }

    func runSetImage(path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("no such file '\(url.path)'", code: 3)
        }
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let frame = FrameRaster.render(image: cgImage, background: CGColor(red: 0, green: 0, blue: 0, alpha: 1)) else {
            fail("could not load image", code: 1)
        }
        pushSingleFrame(frame, kind: .image, description: "image pushed: \(url.lastPathComponent) (\(kSimCamFrameWidth)x\(kSimCamFrameHeight))")
    }

    // MARK: - Helpers

    /// Switch the extension to `kind`, open the sink, push one frame, and
    /// wait until the extension reports it. The extension keeps re-sending
    /// the last frame after the sink closes, so a single push is enough for
    /// a static picture. For a live stream, run the container app instead.
    private func pushSingleFrame(_ frame: CVPixelBuffer, kind: SimCamSourceKind, description: String) {
        attach()
        let before: SimCamStatus
        do {
            before = try client.readStatus()
            try client.openSink()
            try client.setSourceKind(kind)
        } catch {
            fail("could not open the sink stream: \(error.localizedDescription)", code: 1)
        }
        defer { client.closeSink() }

        // Re-enqueue until the extension's received counter moves or we time
        // out. The first buffers may be consumed before a capture client is
        // streaming, in which case the extension still holds the frame.
        let deadline = Date().addingTimeInterval(5)
        var received = false
        while Date() < deadline {
            switch client.enqueue(frame) {
            case .enqueued, .dropped:
                break
            case .rejected(let why):
                fail("frame rejected locally: \(why)", code: 1)
            case .sinkClosed:
                fail("sink closed unexpectedly", code: 2)
            }
            Thread.sleep(forTimeInterval: 0.1)
            if let now = try? client.readStatus(), now.framesReceived > before.framesReceived {
                received = true
                break
            }
        }
        guard received else {
            fail("the extension never acknowledged the frame (is it running? check `simcamctl status`)", code: 2)
        }
        print(description)
        exit(0)
    }
}
