//
//  CMIOSinkClient.swift
//  SimulatorCamera shared
//
//  App-side half of the frame path. Uses the CoreMediaIO C API to
//
//    1. find the virtual camera device by name,
//    2. find its source (camera) and sink (input) streams,
//    3. read / write the extension's custom properties on the source stream,
//    4. open the sink stream's CMSimpleQueue and start it,
//    5. enqueue IOSurface-backed CMSampleBuffers.
//
//  Thread-safety: every entry point takes `lock`. `enqueue` is designed to
//  be called from capture / decode threads at frame rate; the lock is held
//  only for the pointer reads and the queue count check.
//
//  Ownership notes (the parts that are easy to get wrong):
//    - CMIOObjectGetPropertyData hands back a +1 CFString → takeRetainedValue.
//    - CMIOStreamCopyBufferQueue hands back a +1 CMSimpleQueue → we own it.
//    - CMSimpleQueueEnqueue takes ownership of a +1 CMSampleBuffer
//      (passRetained); CoreMediaIO releases it after handing it to the
//      extension.
//

import Foundation
import CoreMedia
import CoreMediaIO
import CoreVideo

public enum CMIOSinkClientError: LocalizedError, Equatable {
    case deviceNotFound
    case streamsNotFound
    case propertyMissing(String)
    case osStatus(String, OSStatus)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "\"\(kSimCamDeviceName)\" is not registered. Is the camera extension activated?"
        case .streamsNotFound:
            return "The virtual camera does not expose a sink stream (older extension build?)."
        case .propertyMissing(let name):
            return "The virtual camera does not expose property \"\(name)\"."
        case .osStatus(let what, let status):
            return "\(what) failed (OSStatus \(status))."
        }
    }
}

public final class CMIOSinkClient: @unchecked Sendable {

    // MARK: State

    private let lock = NSLock()
    private var deviceID: CMIODeviceID = 0
    private var sourceStreamID: CMIOStreamID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var sinkQueue: CMSimpleQueue?
    private var sinkStarted = false

    /// Frames refused because the sink queue was full.
    private var _dropped = 0
    public var framesDropped: Int { lock.lock(); defer { lock.unlock() }; return _dropped }

    public init() {}

    deinit {
        closeSink()
    }

    /// True once the device and both streams have been located.
    public var isAttached: Bool {
        lock.lock(); defer { lock.unlock() }
        return deviceID != 0 && sourceStreamID != 0 && sinkStreamID != 0
    }

    public var isSinkOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return sinkStarted
    }

    // MARK: Discovery

    /// Locate the virtual camera and its streams. Safe to call repeatedly;
    /// re-resolves IDs every time (they change when the extension restarts).
    public func attach() throws {
        guard let device = Self.findDevice(named: kSimCamDeviceName) else {
            throw CMIOSinkClientError.deviceNotFound
        }
        let streams = Self.streams(of: device)
        var source: CMIOStreamID = 0
        var sink: CMIOStreamID = 0
        // Match by the names we registered; fall back to the direction flag
        // (1 = input stream, i.e. camera → host; 0 = output, host → camera).
        for stream in streams {
            switch Self.stringProperty(stream, kCMIOObjectPropertyName) {
            case kSimCamSourceStreamName?: source = stream
            case kSimCamSinkStreamName?: sink = stream
            default:
                switch Self.direction(of: stream) {
                case 1 where source == 0: source = stream
                case 0 where sink == 0: sink = stream
                default: break
                }
            }
        }
        guard source != 0, sink != 0 else { throw CMIOSinkClientError.streamsNotFound }

        lock.lock()
        let changed = deviceID != device || sourceStreamID != source || sinkStreamID != sink
        if changed, sinkStarted {
            // Extension restarted underneath us: the old queue is dead.
            lock.unlock()
            closeSink()
            lock.lock()
        }
        deviceID = device
        sourceStreamID = source
        sinkStreamID = sink
        lock.unlock()
    }

    /// Forget the device. Closes the sink if open.
    public func detach() {
        closeSink()
        lock.lock()
        deviceID = 0
        sourceStreamID = 0
        sinkStreamID = 0
        lock.unlock()
    }

    // MARK: Control properties

    public func readStatus() throws -> SimCamStatus {
        let raw = try readStringProperty(.status)
        guard let status = SimCamStatus(encoded: raw) else {
            throw CMIOSinkClientError.propertyMissing(SimCamProperty.status.rawValue)
        }
        return status
    }

    public func setSourceKind(_ kind: SimCamSourceKind) throws {
        try writeStringProperty(.sourceKind, value: String(kind.rawValue))
    }

    public func readSourceKind() throws -> SimCamSourceKind {
        let raw = try readStringProperty(.sourceKind)
        return Int(raw).flatMap(SimCamSourceKind.init(rawValue:)) ?? .testPattern
    }

    private func readStringProperty(_ property: SimCamProperty) throws -> String {
        lock.lock()
        let stream = sourceStreamID
        lock.unlock()
        guard stream != 0 else { throw CMIOSinkClientError.deviceNotFound }

        var address = Self.address(property.fourCharCode)
        guard CMIOObjectHasProperty(stream, &address) else {
            throw CMIOSinkClientError.propertyMissing(property.rawValue)
        }
        var dataSize: UInt32 = 0
        var status = CMIOObjectGetPropertyDataSize(stream, &address, 0, nil, &dataSize)
        guard status == noErr else { throw CMIOSinkClientError.osStatus("GetPropertyDataSize", status) }
        guard dataSize >= UInt32(MemoryLayout<Unmanaged<CFString>?>.size) else {
            throw CMIOSinkClientError.propertyMissing(property.rawValue)
        }
        var dataUsed: UInt32 = 0
        var ref: Unmanaged<CFString>?
        status = withUnsafeMutablePointer(to: &ref) { ptr in
            CMIOObjectGetPropertyData(stream, &address, 0, nil, dataSize, &dataUsed, ptr)
        }
        guard status == noErr else { throw CMIOSinkClientError.osStatus("GetPropertyData", status) }
        guard let string = ref?.takeRetainedValue() else {
            throw CMIOSinkClientError.propertyMissing(property.rawValue)
        }
        return string as String
    }

    private func writeStringProperty(_ property: SimCamProperty, value: String) throws {
        lock.lock()
        let stream = sourceStreamID
        lock.unlock()
        guard stream != 0 else { throw CMIOSinkClientError.deviceNotFound }

        var address = Self.address(property.fourCharCode)
        guard CMIOObjectHasProperty(stream, &address) else {
            throw CMIOSinkClientError.propertyMissing(property.rawValue)
        }
        var settable: DarwinBoolean = false
        var status = CMIOObjectIsPropertySettable(stream, &address, &settable)
        guard status == noErr, settable.boolValue else {
            throw CMIOSinkClientError.osStatus("IsPropertySettable", status)
        }
        let cf = value as CFString
        var ref: Unmanaged<CFString>? = Unmanaged.passUnretained(cf)
        status = withUnsafeMutablePointer(to: &ref) { ptr in
            CMIOObjectSetPropertyData(
                stream, &address, 0, nil,
                UInt32(MemoryLayout<Unmanaged<CFString>?>.size), ptr
            )
        }
        guard status == noErr else { throw CMIOSinkClientError.osStatus("SetPropertyData", status) }
        withExtendedLifetime(cf) {}
    }

    // MARK: Sink lifecycle

    /// Open the sink queue and start the sink stream. Idempotent.
    public func openSink() throws {
        lock.lock()
        if sinkStarted { lock.unlock(); return }
        let device = deviceID
        let sink = sinkStreamID
        lock.unlock()
        guard device != 0, sink != 0 else { throw CMIOSinkClientError.deviceNotFound }

        var queueRef: Unmanaged<CMSimpleQueue>?
        // No "queue altered" callback: we size our own pacing by frame rate
        // and use the queue count as backpressure instead.
        let copyStatus = withUnsafeMutablePointer(to: &queueRef) { ptr in
            CMIOStreamCopyBufferQueue(sink, nil, nil, ptr)
        }
        guard copyStatus == noErr, let queue = queueRef?.takeRetainedValue() else {
            throw CMIOSinkClientError.osStatus("CMIOStreamCopyBufferQueue", copyStatus)
        }

        let startStatus = CMIODeviceStartStream(device, sink)
        guard startStatus == noErr else {
            throw CMIOSinkClientError.osStatus("CMIODeviceStartStream", startStatus)
        }

        lock.lock()
        sinkQueue = queue
        sinkStarted = true
        _dropped = 0
        lock.unlock()
    }

    /// Stop the sink stream and release the queue. Idempotent.
    public func closeSink() {
        lock.lock()
        guard sinkStarted else { lock.unlock(); return }
        let device = deviceID
        let sink = sinkStreamID
        sinkStarted = false
        lock.unlock()
        // Stop first so CoreMediaIO is done with the queue, then drop our
        // reference to it.
        if device != 0, sink != 0 {
            CMIODeviceStopStream(device, sink)
        }
        lock.lock()
        sinkQueue = nil
        lock.unlock()
    }

    // MARK: Frames

    public enum EnqueueResult: Equatable {
        case enqueued
        case dropped          // queue full
        case rejected(String) // wrong geometry / could not wrap
        case sinkClosed
    }

    /// Enqueue one canonical pixel buffer. Never blocks: a full queue drops
    /// the frame and bumps `framesDropped`.
    @discardableResult
    public func enqueue(_ pixelBuffer: CVPixelBuffer) -> EnqueueResult {
        if let problem = SimCamFrameCheck.problem(with: pixelBuffer) {
            return .rejected(problem)
        }
        lock.lock()
        guard sinkStarted, let queue = sinkQueue else {
            lock.unlock()
            return .sinkClosed
        }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
            _dropped += 1
            lock.unlock()
            return .dropped
        }
        lock.unlock()

        guard let sample = FrameRaster.makeSampleBuffer(pixelBuffer) else {
            return .rejected("could not wrap pixel buffer in a sample buffer")
        }
        let retained = Unmanaged.passRetained(sample).toOpaque()
        let status = CMSimpleQueueEnqueue(queue, element: retained)
        if status != noErr {
            // Queue filled between our check and the enqueue; take the
            // reference back so the sample buffer does not leak.
            Unmanaged<CMSampleBuffer>.fromOpaque(retained).release()
            lock.lock(); _dropped += 1; lock.unlock()
            return .dropped
        }
        return .enqueued
    }

    // MARK: CMIO helpers

    private static func address(_ selector: FourCharCode) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private static func idArray(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var address = address(FourCharCode(selector))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        let status = ids.withUnsafeMutableBufferPointer { buf in
            CMIOObjectGetPropertyData(object, &address, 0, nil, dataSize, &dataUsed, buf.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(dataUsed) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func stringProperty(_ object: CMIOObjectID, _ selector: Int) -> String? {
        var address = address(FourCharCode(selector))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<Unmanaged<CFString>?>.size) else {
            return nil
        }
        var dataUsed: UInt32 = 0
        var ref: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &ref) { ptr in
            CMIOObjectGetPropertyData(object, &address, 0, nil, dataSize, &dataUsed, ptr)
        }
        guard status == noErr, let string = ref?.takeRetainedValue() else { return nil }
        return string as String
    }

    /// All CMIO devices currently registered with the system.
    public static func allDevices() -> [(id: CMIODeviceID, name: String)] {
        idArray(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices).map {
            ($0, stringProperty($0, kCMIOObjectPropertyName) ?? "")
        }
    }

    static func findDevice(named name: String) -> CMIODeviceID? {
        allDevices().first { $0.name == name }?.id
    }

    static func streams(of device: CMIODeviceID) -> [CMIOStreamID] {
        idArray(device, kCMIODevicePropertyStreams)
    }

    /// kCMIOStreamPropertyDirection: 1 = input stream (device → host, the
    /// camera feed), 0 = output stream (host → device, our sink). -1 on error.
    static func direction(of stream: CMIOStreamID) -> Int {
        var address = address(FourCharCode(kCMIOStreamPropertyDirection))
        var value: UInt32 = 0
        var dataUsed: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            stream, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &dataUsed, &value
        )
        return status == noErr ? Int(value) : -1
    }
}
