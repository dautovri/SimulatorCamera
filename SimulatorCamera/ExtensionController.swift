//
//  ExtensionController.swift
//  SimulatorCamera
//
//  Owns the OSSystemExtensionRequest lifecycle. The container app loads
//  this on launch and exposes activation state to the UI. The user clicks
//  Activate, the system prompts them to allow in System Settings, then
//  the extension daemon starts and registers the virtual camera.
//
//  check() queries the installed state at launch so a relaunched app
//  reports "Active" instead of "Not checked".
//

import Foundation
import Observation
import OSLog
import SystemExtensions

private let extensionBundleIdentifier = "com.dautov.SimulatorCamera.Extension"

@Observable
@MainActor
final class ExtensionController: NSObject {

    enum State: Equatable {
        case unknown
        case checking
        case inactive            // installed, not yet activated
        case activating          // OS request in flight
        case awaitingApproval    // user needs to click Allow in System Settings
        case active              // running, virtual camera available
        case deactivating
        case error(String)
    }

    private(set) var state: State = .unknown
    private(set) var lastMessage: String = ""

    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "extension")

    /// Requests currently in flight, keyed by identity, so we can tell a
    /// properties query apart from an activation when results come back.
    private var pendingKinds: [ObjectIdentifier: RequestKind] = [:]

    private enum RequestKind {
        case check, activate, deactivate
    }

    override init() {
        super.init()
        // No automatic check on init. The UI calls .check() once it's on screen
        // so we don't fire OS requests during SwiftUI's @State materialization.
    }

    /// Ask the OS whether the extension is already installed and enabled.
    func check() {
        guard state == .unknown || state == .inactive || state == .active else { return }
        state = .checking
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: extensionBundleIdentifier,
            queue: .main
        )
        submit(request, kind: .check)
    }

    func activate() {
        state = .activating
        lastMessage = "Requesting activation…"
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionBundleIdentifier,
            queue: .main
        )
        submit(request, kind: .activate)
        log.info("submitted activation request for \(extensionBundleIdentifier, privacy: .public)")
    }

    func deactivate() {
        state = .deactivating
        lastMessage = "Requesting deactivation…"
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: extensionBundleIdentifier,
            queue: .main
        )
        submit(request, kind: .deactivate)
        log.info("submitted deactivation request")
    }

    private func submit(_ request: OSSystemExtensionRequest, kind: RequestKind) {
        pendingKinds[ObjectIdentifier(request)] = kind
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func finish(_ request: OSSystemExtensionRequest) -> RequestKind? {
        pendingKinds.removeValue(forKey: ObjectIdentifier(request))
    }
}

// MARK: - OSSystemExtensionRequestDelegate

extension ExtensionController: OSSystemExtensionRequestDelegate {

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Replace older with newer version automatically.
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.state = .awaitingApproval
            self.lastMessage = "Open System Settings → General → Login Items & Extensions → Camera Extensions and allow SimulatorCamera."
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        Task { @MainActor in
            _ = self.finish(request)
            if let enabled = properties.first(where: { $0.isEnabled && !$0.isAwaitingUserApproval }) {
                self.state = .active
                self.lastMessage = "Extension v\(enabled.bundleShortVersion) is active."
            } else if properties.contains(where: { $0.isAwaitingUserApproval }) {
                self.state = .awaitingApproval
                self.lastMessage = "Extension installed but not yet allowed. Approve it in System Settings → General → Login Items & Extensions → Camera Extensions."
            } else {
                self.state = .inactive
                self.lastMessage = properties.isEmpty
                    ? "Extension not installed. Click Activate."
                    : "Extension installed but disabled. Click Activate."
            }
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            let kind = self.finish(request)
            switch result {
            case .completed:
                if kind == .deactivate {
                    self.state = .inactive
                    self.lastMessage = "Extension deactivated."
                } else {
                    self.state = .active
                    self.lastMessage = "Extension active. The virtual camera is now available in AVFoundation."
                }
            case .willCompleteAfterReboot:
                self.state = .awaitingApproval
                self.lastMessage = "Request queued. Reboot to finalize."
            @unknown default:
                self.state = .error("Unexpected activation result.")
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            let kind = self.finish(request)
            if kind == .check {
                // Properties queries fail on unsupported OS builds; degrade to
                // "inactive" so the Activate button still works.
                self.state = .inactive
                self.lastMessage = "Could not query extension state: \(error.localizedDescription)"
            } else {
                self.state = .error(error.localizedDescription)
                self.lastMessage = "Request failed: \(error.localizedDescription)"
            }
            self.log.error("system extension request failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
