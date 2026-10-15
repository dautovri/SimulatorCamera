//
//  CameraLink.swift
//  SimulatorCamera
//
//  Container-side connection to the running camera extension. Wraps
//  CMIOSinkClient with observable state for the UI and a self-healing
//  attach loop:
//
//    - connect() locates the virtual camera and its streams. If the device
//      is not there yet (extension not approved, or restarting) it retries
//      with capped backoff and also listens for AVCaptureDevice connection
//      notifications, which fire the moment the extension registers.
//    - pushFrame is nonisolated and safe from any thread: the capture /
//      decode queues hand pixel buffers straight to the sink queue. Frames
//      are dropped, not queued, when the extension falls behind.
//    - setSource writes the extension's source-kind property; status polls
//      the status property once a second while the window is open.
//

import Foundation
import AVFoundation
import OSLog
import Observation

@Observable
@MainActor
final class CameraLink {

    enum ConnectionState: Equatable {
        case disconnected
        case searching
        case connected
        case failed(String)
    }

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var extensionStatus: SimCamStatus?
    /// Frames dropped because the sink queue was full.
    private(set) var framesDropped: Int = 0
    /// Frames refused locally (wrong geometry) or because the sink was closed.
    private(set) var framesRejected: Int = 0

    private let client = CMIOSinkClient()
    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "camera-link")
    private var retryTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var wantsConnection = false
    private var deviceObserver: NSObjectProtocol?

    var isConnected: Bool { connectionState == .connected }

    // MARK: - Lifecycle

    func connect() {
        wantsConnection = true
        if deviceObserver == nil {
            deviceObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.attachNow() }
            }
        }
        attachNow()
    }

    func disconnect() {
        wantsConnection = false
        retryTask?.cancel()
        retryTask = nil
        pollTask?.cancel()
        pollTask = nil
        client.detach()
        connectionState = .disconnected
        extensionStatus = nil
    }

    private func attachNow() {
        guard wantsConnection else { return }
        if connectionState != .connected { connectionState = .searching }
        do {
            try client.attach()
            let status = try client.readStatus()
            extensionStatus = status
            connectionState = .connected
            retryAttempt = 0
            retryTask?.cancel()
            retryTask = nil
            startPolling()
            log.info("attached to \(kSimCamDeviceName, privacy: .public)")
        } catch {
            extensionStatus = nil
            connectionState = .failed(error.localizedDescription)
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard wantsConnection, retryTask == nil else { return }
        retryAttempt += 1
        let delay = min(pow(2.0, Double(retryAttempt - 1)), 10.0)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.attachNow()
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.wantsConnection {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.refreshStatus()
            }
        }
    }

    /// One status read; a failure here means the extension went away.
    func refreshStatus() {
        guard client.isAttached else { return }
        do {
            extensionStatus = try client.readStatus()
            framesDropped = client.framesDropped
            if connectionState != .connected { connectionState = .connected }
        } catch {
            log.error("status read failed: \(error.localizedDescription, privacy: .public)")
            extensionStatus = nil
            client.closeSink()
            connectionState = .failed(error.localizedDescription)
            pollTask?.cancel()
            pollTask = nil
            scheduleRetry()
        }
    }

    // MARK: - Control

    /// Open the sink so frames can flow. Call before starting a producer;
    /// frames pushed while the extension still shows the test pattern are
    /// consumed and ignored, so there is no harm in opening early.
    func openSink() throws {
        if !client.isAttached { try client.attach() }
        try client.openSink()
        framesRejected = 0
    }

    /// Declare the active source to the extension. Selecting the test
    /// pattern also closes the sink.
    func setSource(_ kind: SimCamSourceKind) throws {
        if !client.isAttached { try client.attach() }
        if kind == .testPattern {
            client.closeSink()
        } else {
            try client.openSink()
        }
        try client.setSourceKind(kind)
        refreshStatus()
    }

    /// Ask for camera access up front so the sink can start without a
    /// surprise TCC prompt from inside a capture callback.
    func requestCameraAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: - Frames

    /// Hand one canonical pixel buffer to the extension. Safe from any thread.
    nonisolated func pushFrame(_ pixelBuffer: CVPixelBuffer) {
        switch client.enqueue(pixelBuffer) {
        case .enqueued, .dropped:
            break
        case .rejected, .sinkClosed:
            Task { @MainActor [weak self] in self?.framesRejected += 1 }
        }
    }
}
