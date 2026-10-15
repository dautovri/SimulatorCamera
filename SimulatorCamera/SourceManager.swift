//
//  SourceManager.swift
//  SimulatorCamera
//
//  Owns the active FrameSource. UI calls switchTo(.macCamera, ...) etc.
//  Manager: stops the old source, starts the new one, pipes frames to
//  XPCClient.pushFrame, tells the extension via setSource.
//

import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class SourceManager {

    enum SwitchError: LocalizedError {
        case noFileSelected
        case noPayloadProvided
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .noFileSelected: return "Pick a file first."
            case .noPayloadProvided: return "Type a QR payload first."
            case .startFailed(let m): return m
            }
        }
    }

    private(set) var activeKind: SimCamSourceKind = .testPattern
    private(set) var lastError: String?
    private(set) var framesPushed: Int = 0
    private(set) var lastFrameTimestamp: Double = 0

    /// User input fields the UI binds to.
    var selectedFileURL: URL?
    var selectedImageURL: URL?
    var qrPayload: String = "https://github.com/dautovri/SimulatorCamera"

    private var activeSource: FrameSource?
    private let xpc: XPCClient
    /// Frames for iOS Simulator apps (SimulatorInjection reads this file). The
    /// Simulator cannot see CMIO cameras, so this is how they reach it.
    private let frameStore = FrameStore()
    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "source-manager")

    init(xpc: XPCClient) {
        self.xpc = xpc
    }

    /// Switch to the given source kind. Throws on user-correctable issues
    /// (no file selected, no QR payload). Returns immediately; the source
    /// runs async until stop or another switch.
    func switchTo(_ kind: SimCamSourceKind) async throws {
        // Stop whatever's running.
        activeSource?.stop()
        activeSource = nil
        framesPushed = 0
        lastError = nil

        // Tell the extension which source is active so the test-pattern timer
        // gates correctly.
        xpc.setSource(kind)
        activeKind = kind

        // testPattern needs no container-side source.
        if kind == .testPattern { return }

        // Build the new source.
        let source: FrameSource
        switch kind {
        case .testPattern:
            return
        case .macCamera:
            source = MacCameraSource()
        case .videoFile:
            guard let url = selectedFileURL else { throw SwitchError.noFileSelected }
            source = VideoFileSource(url: url)
        case .image:
            guard let url = selectedImageURL else { throw SwitchError.noFileSelected }
            source = ImageSource(url: url)
        case .qrCode:
            let payload = qrPayload.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { throw SwitchError.noPayloadProvided }
            source = QRSource(payload: payload)
        }

        // Wire frame hook to XPC pump. Capture-queue thread is fine; XPCClient
        // serializes into NSXPCConnection internally.
        let store = frameStore
        let kindRaw = UInt32(kind.rawValue)
        source.onFrame = { [weak self] frame in
            store.write(frame, sourceKind: kindRaw) // capture queue; FrameStore locks internally
            // Hop to main actor for state mutation only; the push itself is
            // fire-and-forget XPC.
            Task { @MainActor [weak self] in
                self?.xpc.pushFrame(frame)
                self?.framesPushed += 1
                self?.lastFrameTimestamp = frame.timestampSeconds
            }
        }

        do {
            try await source.start()
            activeSource = source
            log.info("source switched to \(String(describing: kind), privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            // Roll back to test pattern.
            xpc.setSource(.testPattern)
            activeKind = .testPattern
            throw SwitchError.startFailed(error.localizedDescription)
        }
    }

    func stop() {
        activeSource?.stop()
        activeSource = nil
        xpc.setSource(.testPattern)
        activeKind = .testPattern
        framesPushed = 0
    }
}
