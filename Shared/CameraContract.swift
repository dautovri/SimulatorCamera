//
//  CameraContract.swift
//  SimulatorCamera shared
//
//  Everything the container app, simcamctl and the camera extension have to
//  agree on. There is no private IPC channel: the app talks to the extension
//  purely through CoreMediaIO.
//
//    frames   → the extension publishes a *sink* stream next to its camera
//               (source) stream. The app opens the sink with the CMIO C API,
//               enqueues IOSurface-backed CMSampleBuffers, and the extension
//               forwards them to whoever is capturing from the camera.
//    control  → custom properties on the source stream (source kind, status).
//
//  Every frame is a canonical 1280x720 BGRA image: the container normalizes
//  all sources to that size, both streams advertise exactly that format, and
//  the extension drops anything else.
//

import Foundation
import CoreMedia
import CoreMediaIO

// MARK: - Canonical frame geometry

/// Width / height / rate of every frame the virtual camera emits.
public let kSimCamFrameWidth: Int = 1280
public let kSimCamFrameHeight: Int = 720
public let kSimCamFrameRate: Int = 30
public let kSimCamBytesPerPixel: Int = 4

// MARK: - Device / stream identity

/// Localized name of the virtual camera device; what AVFoundation clients
/// and the CMIO device enumeration in `CMIOSinkClient` look for.
public let kSimCamDeviceName = "SimulatorCamera Virtual"
public let kSimCamSourceStreamName = "SimulatorCamera.Video"
public let kSimCamSinkStreamName = "SimulatorCamera.Video.Sink"

/// Number of frames the sink queue may hold before the app drops new ones.
/// At 30 fps four buffers is ~130 ms of slack — enough to ride out scheduler
/// hiccups, small enough that a stalled extension never eats memory.
public let kSimCamSinkQueueDepth: Int = 4

// MARK: - Custom properties

/// Custom CMIO properties the extension exposes on its *source* stream.
/// CMIOExtension spells them `4cc_<code>_glob_0000`; clients address them by
/// the four-char `code` with global scope / main element.
public enum SimCamProperty: String, CaseIterable, Sendable {
    /// Settable. Integer-as-string `SimCamSourceKind.rawValue`. testPattern
    /// means "ignore the sink, draw the built-in pattern"; anything else means
    /// "forward sink frames, hold the last one if the sink goes quiet".
    case sourceKind = "srck"
    /// Read-only. `SimCamStatus` encoded with `SimCamStatus.encoded`.
    case status = "stat"

    public var fourCharCode: FourCharCode {
        var code: FourCharCode = 0
        for byte in rawValue.utf8 { code = code << 8 | FourCharCode(byte) }
        return code
    }

    /// Name the extension registers with `CMIOExtensionProperty(rawValue:)`.
    public var extensionPropertyName: String { "4cc_\(rawValue)_glob_0000" }
}

// MARK: - Source kinds

/// What the container is currently sourcing frames from.
public enum SimCamSourceKind: Int, Sendable, CaseIterable {
    case testPattern = 0   // built into extension; no sink frames needed
    case macCamera = 1     // container's AVCaptureSession
    case videoFile = 2     // container's AVAssetReader
    case image = 3         // container's static CGImage
    case qrCode = 4        // container's CIQRCodeGenerator

    public var label: String {
        switch self {
        case .testPattern: return "test pattern"
        case .macCamera: return "mac camera"
        case .videoFile: return "video file"
        case .image: return "static image"
        case .qrCode: return "QR code"
        }
    }
}

// MARK: - Status snapshot

/// Snapshot of extension state, travels as a `key=value` string in the
/// `SimCamProperty.status` property. Kept as plain text so it survives the
/// CFString plumbing of CMIOObjectGetPropertyData and stays greppable.
public struct SimCamStatus: Equatable, Sendable {
    public var activeSourceKind: SimCamSourceKind
    /// CMIO clients currently connected to the provider (Simulator, apps).
    public var connectedClientCount: Int
    /// Whether at least one client is capturing from the camera stream.
    public var isStreamRunning: Bool
    /// Whether a producer (app / CLI) currently has the sink stream open.
    public var isSinkOpen: Bool
    /// Host-clock seconds of the last frame received on the sink.
    public var lastFrameTimestampSeconds: Double
    /// Sink frames accepted since the extension started.
    public var framesReceived: Int
    /// Sink frames dropped because they did not match the canonical format.
    public var framesRejected: Int

    public init(
        activeSourceKind: SimCamSourceKind = .testPattern,
        connectedClientCount: Int = 0,
        isStreamRunning: Bool = false,
        isSinkOpen: Bool = false,
        lastFrameTimestampSeconds: Double = 0,
        framesReceived: Int = 0,
        framesRejected: Int = 0
    ) {
        self.activeSourceKind = activeSourceKind
        self.connectedClientCount = connectedClientCount
        self.isStreamRunning = isStreamRunning
        self.isSinkOpen = isSinkOpen
        self.lastFrameTimestampSeconds = lastFrameTimestampSeconds
        self.framesReceived = framesReceived
        self.framesRejected = framesRejected
    }

    public var encoded: String {
        [
            "source=\(activeSourceKind.rawValue)",
            "clients=\(connectedClientCount)",
            "streaming=\(isStreamRunning ? 1 : 0)",
            "sink=\(isSinkOpen ? 1 : 0)",
            "last=\(lastFrameTimestampSeconds)",
            "received=\(framesReceived)",
            "rejected=\(framesRejected)",
        ].joined(separator: " ")
    }

    /// Tolerant parser: unknown keys are ignored, missing keys keep defaults,
    /// so an older CLI can still read a newer extension's status.
    public init?(encoded: String) {
        var fields: [String: String] = [:]
        for pair in encoded.split(separator: " ") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            fields[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        guard let sourceRaw = fields["source"].flatMap(Int.init) else { return nil }
        self.init(
            activeSourceKind: SimCamSourceKind(rawValue: sourceRaw) ?? .testPattern,
            connectedClientCount: fields["clients"].flatMap(Int.init) ?? 0,
            isStreamRunning: fields["streaming"] == "1",
            isSinkOpen: fields["sink"] == "1",
            lastFrameTimestampSeconds: fields["last"].flatMap(Double.init) ?? 0,
            framesReceived: fields["received"].flatMap(Int.init) ?? 0,
            framesRejected: fields["rejected"].flatMap(Int.init) ?? 0
        )
    }
}

// MARK: - Frame validation

public enum SimCamFrameCheck {
    /// Nil when `pixelBuffer` is exactly what the streams advertise.
    public static func problem(with pixelBuffer: CVPixelBuffer) -> String? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_32BGRA else {
            return "pixel format \(format) is not BGRA"
        }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w == kSimCamFrameWidth, h == kSimCamFrameHeight else {
            return "\(w)x\(h) is not \(kSimCamFrameWidth)x\(kSimCamFrameHeight)"
        }
        return nil
    }
}
