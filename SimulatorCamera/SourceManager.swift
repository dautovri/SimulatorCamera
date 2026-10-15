//
//  SourceManager.swift
//  SimulatorCamera
//
//  Owns the active FrameSource. UI calls switchTo(.macCamera, ...) etc.
//  Manager: stops the old source, starts the new one, pipes frames to
//  CameraLink.pushFrame, tells the extension which source is live.
//
//  Switches are serialized by a generation counter: if the user clicks
//  twice while a camera is still warming up, the first start is discarded
//  when it finally completes instead of leaking a running source.
//

import Foundation
import CoreVideo
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
    private(set) var isSwitching = false
    private(set) var lastError: String?
    private(set) var framesPushed: Int = 0

    /// User input fields the UI binds to.
    var selectedFileURL: URL?
    var selectedImageURL: URL?
    var qrPayload: String = "https://github.com/dautovri/SimulatorCamera"

    private var activeSource: FrameSource?
    private var switchGeneration = 0
    private let link: CameraLink
    /// Frames for iOS Simulator apps (SimulatorInjection reads this file). The
    /// Simulator cannot see CMIO cameras, so this is how they reach it.
    private let frameStore = FrameStore()
    private var testPattern: TestPatternSource?
    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "source-manager")

    init(link: CameraLink) {
        self.link = link
        // Simulator apps get the test pattern as soon as the app is open.
        Task { @MainActor [weak self] in try? await self?.switchTo(.testPattern) }
    }

    /// Switch to the given source kind. Throws on user-correctable issues
    /// (no file selected, no QR payload) and on start failures. Returns
    /// once the new source is running; it keeps running until stop() or
    /// another switch.
    func switchTo(_ kind: SimCamSourceKind) async throws {
        switchGeneration += 1
        let generation = switchGeneration

        // Stop whatever's running.
        tearDownActiveSource()
        lastError = nil

        // The extension draws its own test pattern for macOS apps; simulator
        // apps get this container-side one through the frame file. No sink
        // and no camera access needed.
        if kind == .testPattern {
            let pattern = TestPatternSource()
            let store = frameStore
            pattern.onFrame = { frame in store.write(frame, sourceKind: UInt32(SimCamSourceKind.testPattern.rawValue)) }
            try? await pattern.start()
            guard switchGeneration == generation else { pattern.stop(); return }
            testPattern = pattern
            declare(.testPattern)
            return
        }

        // Build the new source.
        let source: FrameSource
        switch kind {
        case .testPattern:
            return // handled above
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

        isSwitching = true
        defer { if switchGeneration == generation { isSwitching = false } }

        // The extension's sink feeds macOS apps. It needs camera access (TCC
        // gates CMIO device streams) and an approved extension. Simulator apps
        // don't need either, so a missing sink is reported but not fatal.
        var sinkOpen = false
        if await link.requestCameraAccessIfNeeded() {
            do { try link.openSink(); sinkOpen = true }
            catch { lastError = "Extension not reachable (simulator apps still get frames): \(error.localizedDescription)" }
        } else {
            lastError = "Camera access denied: macOS apps won't see this source; simulator apps still do."
        }

        // Frames go straight to the sink and the frame file from the
        // producer's thread; only the counter hops to the main actor.
        let link = self.link
        let store = frameStore
        let kindRaw = UInt32(kind.rawValue)
        var localCount = 0
        source.onFrame = { [weak self] frame in
            store.write(frame, sourceKind: kindRaw)
            if sinkOpen { link.pushFrame(frame) }
            localCount += 1
            if localCount % 10 == 0 {
                let count = localCount
                Task { @MainActor [weak self] in
                    guard let self, self.switchGeneration == generation else { return }
                    self.framesPushed = count
                }
            }
        }

        do {
            try await source.start()
        } catch {
            // A newer switch may already own the UI; only report if we're current.
            if switchGeneration == generation {
                lastError = error.localizedDescription
                declare(.testPattern)
            }
            throw SwitchError.startFailed(error.localizedDescription)
        }

        // Lost the race to a newer switch while starting: discard quietly.
        guard switchGeneration == generation else {
            source.stop()
            return
        }

        activeSource = source
        activeKind = kind
        framesPushed = 0
        // Tell the extension only once frames are actually flowing, so the
        // test pattern keeps running during a slow camera warm-up instead
        // of freezing the virtual camera.
        declare(kind)
        log.info("source switched to \(kind.label, privacy: .public)")
    }

    func stop() {
        switchGeneration += 1
        tearDownActiveSource()
        declare(.testPattern)
        isSwitching = false
    }

    /// Tell the extension which source is live; failures are surfaced in
    /// the UI but do not stop the local source (the link retries on its own).
    private func declare(_ kind: SimCamSourceKind) {
        activeKind = kind
        do {
            try link.setSource(kind)
        } catch {
            lastError = "Extension not reachable: \(error.localizedDescription)"
            log.error("setSource failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func tearDownActiveSource() {
        testPattern?.stop()
        testPattern = nil
        activeSource?.onFrame = nil
        activeSource?.stop()
        activeSource = nil
        framesPushed = 0
    }
}
