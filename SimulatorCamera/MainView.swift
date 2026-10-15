//
//  MainView.swift
//  SimulatorCamera
//
//  v1.0 UI matching SimCam feature surface: extension activation status,
//  source picker (test pattern, Mac camera, video file, image, QR code),
//  Run Diagnostics, frame counter.
//

import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(ExtensionController.self) private var extensionController
    @Environment(CameraLink.self) private var link
    @Environment(SourceManager.self) private var sourceManager

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                extensionStatusCard
                sourcePicker
                diagnosticsCard
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "video.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("SimulatorCamera")
                .font(.title.bold())
            Text("Your Mac's camera, in the iOS Simulator. Free and open.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Extension status

    private var extensionStatusCard: some View {
        @Bindable var ec = extensionController
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(extensionStatusColor).frame(width: 10, height: 10)
                Text(extensionStatusLabel).font(.headline)
                Spacer()
                Button(extensionActionLabel, action: handleExtensionAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(extensionActionDisabled)
            }
            if !ec.lastMessage.isEmpty {
                Text(ec.lastMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Source picker

    private var sourcePicker: some View {
        @Bindable var sm = sourceManager
        return VStack(alignment: .leading, spacing: 14) {
            Text("Source").font(.headline)

            sourceRow(.testPattern, icon: "tv", title: "Test Pattern", subtitle: "Built into the extension. No setup.")
            sourceRow(.macCamera, icon: "camera.fill", title: "Mac Camera", subtitle: "Live webcam. First use prompts for camera access.")

            Divider()

            videoFileRow
            imageFileRow
            qrRow

            if let err = sourceManager.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }

            HStack {
                Text(frameCounterText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if sourceManager.isSwitching {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if sourceManager.activeKind != .testPattern || sourceManager.isSwitching {
                    Button("Stop") { sourceManager.stop() }
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sourceRow(
        _ kind: SimCamSourceKind,
        icon: String,
        title: String,
        subtitle: String
    ) -> some View {
        let isActive = sourceManager.activeKind == kind
        return Button {
            switchSource(kind)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(isActive ? .semibold : .regular))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private var videoFileRow: some View {
        @Bindable var sm = sourceManager
        return HStack(spacing: 10) {
            Image(systemName: "film.fill")
                .font(.title3)
                .foregroundStyle(sourceManager.activeKind == .videoFile ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Video File").font(.callout)
                Text(sourceManager.selectedFileURL?.lastPathComponent ?? "Pick an MP4 / MOV file…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Browse…") { pickVideoFile() }.controlSize(.small)
            Button("Use") { switchSource(.videoFile) }
            .controlSize(.small)
            .disabled(sourceManager.selectedFileURL == nil || sourceManager.isSwitching)
        }
    }

    private var imageFileRow: some View {
        return HStack(spacing: 10) {
            Image(systemName: "photo.fill")
                .font(.title3)
                .foregroundStyle(sourceManager.activeKind == .image ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Static Image").font(.callout)
                Text(sourceManager.selectedImageURL?.lastPathComponent ?? "Pick a PNG / JPG file…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Browse…") { pickImageFile() }.controlSize(.small)
            Button("Use") { switchSource(.image) }
            .controlSize(.small)
            .disabled(sourceManager.selectedImageURL == nil || sourceManager.isSwitching)
        }
    }

    private var qrRow: some View {
        @Bindable var sm = sourceManager
        return HStack(spacing: 10) {
            Image(systemName: "qrcode")
                .font(.title3)
                .foregroundStyle(sourceManager.activeKind == .qrCode ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("QR Code").font(.callout)
                TextField("Payload (URL or string)", text: $sm.qrPayload)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            Button("Generate") { switchSource(.qrCode) }
            .controlSize(.small)
            .disabled(sourceManager.qrPayload.trimmingCharacters(in: .whitespaces).isEmpty || sourceManager.isSwitching)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Diagnostics").font(.headline)
                Spacer()
                Button("Run Diagnostics") {
                    runDiagnostics()
                }
                .controlSize(.small)
            }
            HStack(spacing: 16) {
                diagnosticItem("Extension", state: extensionStatusLabel, ok: extensionController.state == .active)
                diagnosticItem("Camera link", state: linkStateDescription, ok: link.isConnected)
                diagnosticItem("Capture", state: captureDescription, ok: link.extensionStatus?.isStreamRunning == true)
                diagnosticItem("Delivery", state: deliveryDescription, ok: link.framesRejected == 0)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func diagnosticItem(_ name: String, state: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption.bold())
            HStack(spacing: 4) {
                Circle().fill(ok ? Color.green : Color.gray).frame(width: 6, height: 6)
                Text(state).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Once active, the iOS Simulator sees '\(kSimCamDeviceName)'")
                .font(.caption.bold())
            Text("AVCaptureDevice.default(for: .video) returns it. Existing camera code Just Works.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived state

    private var extensionStatusColor: Color {
        switch extensionController.state {
        case .unknown, .checking, .inactive: return .gray
        case .activating, .awaitingApproval, .deactivating: return .orange
        case .active: return .green
        case .error: return .red
        }
    }

    private var extensionStatusLabel: String {
        switch extensionController.state {
        case .unknown: return "Not checked"
        case .checking: return "Checking…"
        case .inactive: return "Inactive"
        case .activating: return "Activating…"
        case .awaitingApproval: return "Awaiting approval"
        case .active: return "Active"
        case .deactivating: return "Deactivating…"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var extensionActionLabel: String {
        switch extensionController.state {
        case .active: return "Deactivate"
        case .activating, .deactivating: return "Working…"
        default: return "Activate"
        }
    }

    private var extensionActionDisabled: Bool {
        switch extensionController.state {
        case .activating, .deactivating, .checking: return true
        default: return false
        }
    }

    private var frameCounterText: String {
        var parts = ["Frames pushed: \(sourceManager.framesPushed)"]
        if link.framesDropped > 0 { parts.append("dropped: \(link.framesDropped)") }
        if link.framesRejected > 0 { parts.append("rejected: \(link.framesRejected)") }
        if let received = link.extensionStatus?.framesReceived, received > 0 {
            parts.append("received by extension: \(received)")
        }
        return parts.joined(separator: " · ")
    }

    private var deliveryDescription: String {
        if link.framesRejected > 0 {
            return "\(link.framesRejected) rejected — sink not open?"
        }
        if link.framesDropped > 0 {
            return "\(link.framesDropped) dropped (extension busy)"
        }
        if let rejected = link.extensionStatus?.framesRejected, rejected > 0 {
            return "extension rejected \(rejected)"
        }
        return "OK"
    }

    private var captureDescription: String {
        guard let status = link.extensionStatus else { return "Unknown" }
        if status.isStreamRunning {
            return "\(status.connectedClientCount) client(s) capturing"
        }
        return "No app is capturing from the virtual camera"
    }

    private var linkStateDescription: String {
        switch link.connectionState {
        case .disconnected: return "Disconnected"
        case .searching: return "Looking for the virtual camera…"
        case .connected: return "Connected"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    // MARK: - Actions

    private func switchSource(_ kind: SimCamSourceKind) {
        Task {
            do {
                try await sourceManager.switchTo(kind)
            } catch {
                // switchTo already surfaced the message via lastError; nothing to add.
            }
        }
    }

    private func handleExtensionAction() {
        switch extensionController.state {
        case .active: extensionController.deactivate()
        default: extensionController.activate()
        }
    }

    private func pickVideoFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sourceManager.selectedFileURL = url
        }
    }

    private func pickImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sourceManager.selectedImageURL = url
        }
    }

    private func runDiagnostics() {
        extensionController.check()
        link.connect()
        link.refreshStatus()
    }
}
