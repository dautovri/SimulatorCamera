//
//  SimulatorCameraProvider.swift
//  SimulatorCameraExtension
//
//  CMIOExtensionProvider + DeviceSource + two StreamSources for the
//  "SimulatorCamera Virtual" camera:
//
//    source stream  "SimulatorCamera.Video"       camera → clients
//    sink stream    "SimulatorCamera.Video.Sink"  container app → camera
//
//  The container app enqueues canonical 1280x720 BGRA frames on the sink;
//  the device source forwards them to the source stream. When no producer
//  is attached (or the app asked for it) a built-in scrolling-stripe test
//  pattern is generated on a timer. When a producer goes quiet mid-stream
//  the last received frame is re-sent so clients see a frozen picture with
//  fresh timestamps instead of a stalled capture session.
//
//  Control travels as custom properties on the source stream
//  (`SimCamProperty`), the mechanism Apple recommends for app ↔ camera
//  extension communication.
//

import Foundation
import CoreMediaIO
import IOKit.audio
import os.log

private let kWhiteStripeHeight: Int = 10
private let log = Logger(subsystem: "com.dautov.SimulatorCamera.Extension", category: "provider")

// Stable UUIDs so System Profiler / AVCaptureDevice see the same device
// across launches. Generated once with `uuidgen`.
private let kDeviceUUID = UUID(uuidString: "6F58C7E7-5C3A-4A0E-9F7E-9F0E3D8F1A0B")!
private let kSourceStreamUUID = UUID(uuidString: "D2E4B9F1-7A3C-4D8E-A0B2-3F5E7D9C1B0A")!
private let kSinkStreamUUID = UUID(uuidString: "8A1C2E4F-6B7D-4F90-9E21-5C3A7B9D1F42")!

private let kSourceKindProperty = CMIOExtensionProperty(rawValue: SimCamProperty.sourceKind.extensionPropertyName)
private let kStatusProperty = CMIOExtensionProperty(rawValue: SimCamProperty.status.extensionPropertyName)

/// If the sink delivers nothing for this long while a non-pattern source is
/// selected, the timer starts re-sending the last frame.
private let kSinkHoldThreshold: Double = 2.0 / Double(kSimCamFrameRate)

// MARK: - Device Source

final class SimulatorCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var _sourceStream: SimulatorCameraSourceStream!
    private var _sinkStream: SimulatorCameraSinkStream!

    private let _lock = NSLock()

    /// Number of CMIO clients that asked us to stream from the camera.
    private var _streamingCounter: UInt32 = 0
    /// Number of producers that opened the sink.
    private var _sinkCounter: UInt32 = 0
    private var _sinkClient: CMIOExtensionClient?
    private var _sinkConsumeGeneration: UInt64 = 0

    /// Active source kind as declared by the container app.
    private var _activeSource: SimCamSourceKind = .testPattern

    /// Last frame received on the sink, kept for hold-last-frame.
    private var _lastSinkBuffer: CVPixelBuffer?
    private var _lastSinkHostSeconds: Double = 0
    private var _framesReceived = 0
    private var _framesRejected = 0
    private var _connectedClients = 0

    private var _timer: DispatchSourceTimer?
    private let _timerQueue = DispatchQueue(
        label: "com.dautov.SimulatorCameraExtension.timer",
        qos: .userInteractive,
        attributes: [],
        autoreleaseFrequency: .workItem,
        target: .global(qos: .userInteractive)
    )

    private var _videoDescription: CMFormatDescription!
    private var _bufferPool: CVPixelBufferPool!
    private var _bufferAuxAttributes: NSDictionary!

    private var _whiteStripeStartRow: UInt32 = 0
    private var _whiteStripeIsAscending: Bool = false

    var activeSource: SimCamSourceKind {
        get { _lock.lock(); defer { _lock.unlock() }; return _activeSource }
        set {
            _lock.lock()
            _activeSource = newValue
            if newValue == .testPattern { _lastSinkBuffer = nil }
            _lock.unlock()
            log.info("source kind → \(newValue.label, privacy: .public)")
        }
    }

    var isStreaming: Bool {
        _lock.lock(); defer { _lock.unlock() }
        return _streamingCounter > 0
    }

    var status: SimCamStatus {
        _lock.lock(); defer { _lock.unlock() }
        return SimCamStatus(
            activeSourceKind: _activeSource,
            connectedClientCount: _connectedClients,
            isStreamRunning: _streamingCounter > 0,
            isSinkOpen: _sinkCounter > 0,
            lastFrameTimestampSeconds: _lastSinkHostSeconds,
            framesReceived: _framesReceived,
            framesRejected: _framesRejected
        )
    }

    func setConnectedClients(_ count: Int) {
        _lock.lock(); _connectedClients = count; _lock.unlock()
    }

    init(localizedName: String) {
        super.init()

        self.device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: kDeviceUUID,
            legacyDeviceID: nil,
            source: self
        )

        let dims = CMVideoDimensions(width: Int32(kSimCamFrameWidth), height: Int32(kSimCamFrameHeight))
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: dims.width,
            height: dims.height,
            extensions: nil,
            formatDescriptionOut: &_videoDescription
        )

        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: dims.width,
            kCVPixelBufferHeightKey: dims.height,
            kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &_bufferPool)
        _bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]

        let frameDuration = CMTime(value: 1, timescale: Int32(kSimCamFrameRate))
        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: _videoDescription,
            maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration,
            validFrameDurations: nil
        )

        _sourceStream = SimulatorCameraSourceStream(
            localizedName: kSimCamSourceStreamName,
            streamID: kSourceStreamUUID,
            streamFormat: streamFormat,
            device: device
        )
        _sinkStream = SimulatorCameraSinkStream(
            localizedName: kSimCamSinkStreamName,
            streamID: kSinkStreamUUID,
            streamFormat: streamFormat,
            device: device
        )
        do {
            try device.addStream(_sourceStream.stream)
            try device.addStream(_sinkStream.stream)
        } catch {
            fatalError("Failed to add streams: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = kSimCamDeviceName
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        // No settable device properties.
    }

    // MARK: Source stream lifecycle

    func startStreaming() {
        guard _bufferPool != nil else { return }

        _lock.lock()
        _streamingCounter += 1
        let isFirstClient = _streamingCounter == 1
        _lock.unlock()

        // Only the first client creates the timer. Creating one per client
        // (as Apple's template does) leaks the earlier timers: they keep
        // firing forever, doubling the frame rate and never stopping.
        guard isFirstClient else { return }

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: _timerQueue)
        timer.schedule(
            deadline: .now(),
            repeating: 1.0 / Double(kSimCamFrameRate),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.timerTick()
        }
        _timer?.cancel()
        _timer = timer
        timer.resume()
        log.info("camera stream started")
    }

    func stopStreaming() {
        _lock.lock()
        if _streamingCounter > 0 { _streamingCounter -= 1 }
        let isLastClient = _streamingCounter == 0
        _lock.unlock()

        guard isLastClient else { return }
        _timer?.cancel()
        _timer = nil
        log.info("camera stream stopped")
    }

    /// Runs at the canonical frame rate while someone is capturing.
    private func timerTick() {
        _lock.lock()
        let kind = _activeSource
        let held = _lastSinkBuffer
        let sinkQuietFor = CMClockGetTime(CMClockGetHostTimeClock()).seconds - _lastSinkHostSeconds
        _lock.unlock()

        if kind == .testPattern {
            emitTestPatternFrame()
            return
        }
        // Producer selected. If it is delivering, its frames go out through
        // the sink path and we stay silent. If it went quiet, hold the last
        // frame; if it never delivered anything, show the pattern so the
        // client at least sees motion.
        guard sinkQuietFor > kSinkHoldThreshold else { return }
        if let held {
            _ = send(held)
        } else {
            emitTestPatternFrame()
        }
    }

    // MARK: Sink stream lifecycle

    func startSink(client: CMIOExtensionClient) {
        _lock.lock()
        _sinkCounter += 1
        _sinkClient = client
        _sinkConsumeGeneration += 1
        let generation = _sinkConsumeGeneration
        _lock.unlock()
        log.info("sink opened by pid \(client.pid) (\(client.signingID ?? "unsigned", privacy: .public))")
        consumeNext(client: client, generation: generation)
    }

    func stopSink() {
        _lock.lock()
        if _sinkCounter > 0 { _sinkCounter -= 1 }
        if _sinkCounter == 0 {
            _sinkClient = nil
            _sinkConsumeGeneration += 1   // invalidates the running consume loop
        }
        _lock.unlock()
        log.info("sink closed")
    }

    /// Pull one buffer from the sink, forward it, and re-arm. The generation
    /// check stops the loop once the producer stopped the stream, so a late
    /// callback can never restart consumption on a dead client.
    private func consumeNext(client: CMIOExtensionClient, generation: UInt64) {
        _lock.lock()
        let stillCurrent = _sinkConsumeGeneration == generation && _sinkCounter > 0
        _lock.unlock()
        guard stillCurrent else { return }

        _sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sbuf, seq, _, _, error in
            guard let self else { return }
            if let sbuf {
                self.forward(sbuf, sequenceNumber: seq)
            }
            if let error, sbuf == nil {
                // Re-arm after a short pause so a persistent error (producer
                // died mid-frame, stream torn down) cannot spin this loop.
                log.error("sink consume error: \(error.localizedDescription, privacy: .public)")
                self._timerQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                    self?.consumeNext(client: client, generation: generation)
                }
            } else {
                self.consumeNext(client: client, generation: generation)
            }
        }
    }

    private func forward(_ sbuf: CMSampleBuffer, sequenceNumber: UInt64) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard let pb = CMSampleBufferGetImageBuffer(sbuf) else {
            noteRejected("sample buffer carries no image")
            return
        }
        if let problem = SimCamFrameCheck.problem(with: pb) {
            noteRejected(problem)
            return
        }

        _lock.lock()
        _lastSinkBuffer = pb
        _lastSinkHostSeconds = now.seconds
        _framesReceived += 1
        let streaming = _streamingCounter > 0
        let kind = _activeSource
        _lock.unlock()

        // Tell the producer its buffer has been scheduled so its queue drains.
        let output = CMIOExtensionScheduledOutput(
            sequenceNumber: sequenceNumber,
            hostTimeInNanoseconds: UInt64(max(0, now.seconds) * Double(NSEC_PER_SEC))
        )
        _sinkStream.stream.notifyScheduledOutputChanged(output)

        // Frames arriving while the app says "test pattern" are ignored, so a
        // stray producer cannot override an explicit selection.
        guard streaming, kind != .testPattern else { return }
        _ = send(pb)
    }

    private func noteRejected(_ why: String) {
        _lock.lock()
        _framesRejected += 1
        let count = _framesRejected
        _lock.unlock()
        if count == 1 || count % 300 == 0 {
            log.error("sink frame rejected (\(count) so far): \(why, privacy: .public)")
        }
    }

    // MARK: Frame emission

    /// Pull a buffer from the pool. Nil (and a log line) when the pool is
    /// exhausted, which means the consumer is not draining frames.
    private func dequeuePixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            _bufferPool,
            _bufferAuxAttributes,
            &pixelBuffer
        )
        if err != kCVReturnSuccess {
            log.error("out of pixel buffers (\(err))")
            return nil
        }
        return pixelBuffer
    }

    /// Stamp `pixelBuffer` with the host clock and hand it to the source stream.
    @discardableResult
    private func send(_ pixelBuffer: CVPixelBuffer) -> OSStatus {
        var sbuf: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo()
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        timingInfo.presentationTimeStamp = now
        let err = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: _videoDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sbuf
        )
        guard err == noErr, let sbuf else {
            log.error("CMSampleBufferCreateForImageBuffer failed (\(err))")
            return err
        }
        _sourceStream.stream.send(
            sbuf,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(max(0, now.seconds) * Double(NSEC_PER_SEC))
        )
        return noErr
    }

    /// Generate one frame of the scrolling-white-stripe-on-black test pattern
    /// and push it to the source stream.
    private func emitTestPatternFrame() {
        guard let pixelBuffer = dequeuePixelBuffer() else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            memset(base, 0, rowBytes * height)

            let maxStart = UInt32(max(0, height - kWhiteStripeHeight))
            let stripeStart = min(_whiteStripeStartRow, maxStart)
            if _whiteStripeIsAscending {
                _whiteStripeStartRow = stripeStart > 0 ? stripeStart - 1 : 0
                _whiteStripeIsAscending = _whiteStripeStartRow > 0
            } else {
                _whiteStripeStartRow = stripeStart + 1
                _whiteStripeIsAscending = _whiteStripeStartRow >= maxStart
            }

            var rowPtr = base.advanced(by: rowBytes * Int(stripeStart))
            let rowsToPaint = min(kWhiteStripeHeight, height - Int(stripeStart))
            for _ in 0..<max(0, rowsToPaint) {
                memset(rowPtr, 0xFF, width * kSimCamBytesPerPixel)
                rowPtr += rowBytes
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        send(pixelBuffer)
    }
}

// MARK: - Source (camera) stream

final class SimulatorCameraSourceStream: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat

    init(
        localizedName: String,
        streamID: UUID,
        streamFormat: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice
    ) {
        self.device = device
        self._streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    private var deviceSource: SimulatorCameraDeviceSource {
        guard let deviceSource = device.source as? SimulatorCameraDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        return deviceSource
    }

    var formats: [CMIOExtensionStreamFormat] { [_streamFormat] }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex >= 1 { log.error("Invalid format index \(self.activeFormatIndex)") }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, kSourceKindProperty, kStatusProperty]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: Int32(kSimCamFrameRate))
        }
        if properties.contains(kSourceKindProperty) {
            streamProperties.setPropertyState(
                CMIOExtensionPropertyState(value: String(deviceSource.activeSource.rawValue) as NSString),
                forProperty: kSourceKindProperty
            )
        }
        if properties.contains(kStatusProperty) {
            streamProperties.setPropertyState(
                CMIOExtensionPropertyState(value: deviceSource.status.encoded as NSString),
                forProperty: kStatusProperty
            )
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
        if let state = streamProperties.propertiesDictionary[kSourceKindProperty] {
            let raw = (state.value as? String).flatMap(Int.init)
                ?? (state.value as? NSNumber)?.intValue
            if let raw, let kind = SimCamSourceKind(rawValue: raw) {
                deviceSource.activeSource = kind
            } else {
                log.error("ignoring invalid source kind value \(String(describing: state.value), privacy: .public)")
            }
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        // Anyone may capture from the camera (that is the point).
        true
    }

    func startStream() throws {
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        deviceSource.stopStreaming()
    }
}

// MARK: - Sink (producer) stream

final class SimulatorCameraSinkStream: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat
    private var _client: CMIOExtensionClient?

    init(
        localizedName: String,
        streamID: UUID,
        streamFormat: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice
    ) {
        self.device = device
        self._streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .sink,
            clockType: .hostTime,
            source: self
        )
    }

    private var deviceSource: SimulatorCameraDeviceSource {
        guard let deviceSource = device.source as? SimulatorCameraDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        return deviceSource
    }

    var formats: [CMIOExtensionStreamFormat] { [_streamFormat] }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex >= 1 { log.error("Invalid sink format index \(self.activeFormatIndex)") }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [
            .streamActiveFormatIndex,
            .streamFrameDuration,
            .streamSinkBufferQueueSize,
            .streamSinkBuffersRequiredForStartup,
            .streamSinkBufferUnderrunCount,
            .streamSinkEndOfData,
        ]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: Int32(kSimCamFrameRate))
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = kSimCamSinkQueueDepth
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    /// Only our own binaries may feed the camera. The allowed signing IDs
    /// are derived from the extension's own bundle identifier
    /// (`com.example.App.Extension` → `com.example.App`, `com.example.simcamctl`)
    /// so forks that keep the naming pattern need no changes.
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        let allowed = Self.allowedProducerSigningIDs()
        guard let signingID = client.signingID, allowed.contains(signingID) else {
            log.error("refusing sink producer pid \(client.pid) signingID=\(client.signingID ?? "nil", privacy: .public)")
            return false
        }
        _client = client
        return true
    }

    static func allowedProducerSigningIDs(extensionBundleID: String? = Bundle.main.bundleIdentifier) -> Set<String> {
        guard let ext = extensionBundleID else { return [] }
        let app = ext.hasSuffix(".Extension") ? String(ext.dropLast(".Extension".count)) : ext
        var ids: Set<String> = [app]
        if let dot = app.lastIndex(of: ".") {
            ids.insert(String(app[..<dot]) + ".simcamctl")
        }
        return ids
    }

    func startStream() throws {
        guard let client = _client else {
            throw NSError(domain: "SimulatorCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: "sink started without an authorized client"])
        }
        deviceSource.startSink(client: client)
    }

    func stopStream() throws {
        deviceSource.stopSink()
        _client = nil
    }
}

// MARK: - Provider Source

@objc(SimulatorCameraProviderSource)
final class SimulatorCameraProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: SimulatorCameraDeviceSource!

    private let _clientLock = NSLock()
    private var _clientCount = 0

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = SimulatorCameraDeviceSource(localizedName: kSimCamDeviceName)

        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        _clientLock.lock()
        _clientCount += 1
        let count = _clientCount
        _clientLock.unlock()
        deviceSource.setConnectedClients(count)
        log.info("CMIO client connected pid \(client.pid) (total=\(count))")
    }

    func disconnect(from client: CMIOExtensionClient) {
        _clientLock.lock()
        _clientCount = max(0, _clientCount - 1)
        let count = _clientCount
        _clientLock.unlock()
        deviceSource.setConnectedClients(count)
        log.info("CMIO client disconnected pid \(client.pid) (remaining=\(count))")
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "SimulatorCamera (open source)"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // No settable properties.
    }
}
