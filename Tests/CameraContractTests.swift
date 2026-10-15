//
//  CameraContractTests.swift
//  SimulatorCameraTests
//
//  Pins down the parts of the app ↔ extension contract that, if they
//  regress, blank the virtual camera or break simcamctl.
//

import XCTest
import CoreMedia
import CoreVideo

final class CameraContractTests: XCTestCase {

    // MARK: Custom property naming

    func testPropertyFourCharCodesAreStable() {
        // 'srck' and 'stat' as big-endian four-char codes.
        XCTAssertEqual(SimCamProperty.sourceKind.fourCharCode, 0x7372_636B)
        XCTAssertEqual(SimCamProperty.status.fourCharCode, 0x7374_6174)
    }

    func testExtensionPropertyNamesFollowCMIOConvention() {
        XCTAssertEqual(SimCamProperty.sourceKind.extensionPropertyName, "4cc_srck_glob_0000")
        XCTAssertEqual(SimCamProperty.status.extensionPropertyName, "4cc_stat_glob_0000")
    }

    // MARK: Status encoding

    func testStatusRoundTrips() throws {
        let original = SimCamStatus(
            activeSourceKind: .qrCode,
            connectedClientCount: 3,
            isStreamRunning: true,
            isSinkOpen: true,
            lastFrameTimestampSeconds: 1234.5,
            framesReceived: 42,
            framesRejected: 1
        )
        let decoded = try XCTUnwrap(SimCamStatus(encoded: original.encoded))
        XCTAssertEqual(decoded, original)
    }

    func testStatusParserTolerantOfUnknownAndMissingKeys() throws {
        let decoded = try XCTUnwrap(SimCamStatus(encoded: "source=1 future=xyz streaming=1"))
        XCTAssertEqual(decoded.activeSourceKind, .macCamera)
        XCTAssertTrue(decoded.isStreamRunning)
        XCTAssertFalse(decoded.isSinkOpen)
        XCTAssertEqual(decoded.framesReceived, 0)
    }

    func testStatusParserRejectsGarbage() {
        XCTAssertNil(SimCamStatus(encoded: ""))
        XCTAssertNil(SimCamStatus(encoded: "hello world"))
        XCTAssertNil(SimCamStatus(encoded: "source=abc"))
    }

    func testUnknownSourceKindFallsBackToTestPattern() throws {
        let decoded = try XCTUnwrap(SimCamStatus(encoded: "source=99"))
        XCTAssertEqual(decoded.activeSourceKind, .testPattern)
    }

    // MARK: Frame validation

    func testCanonicalPixelBufferPasses() throws {
        let pb = try XCTUnwrap(FrameRaster.makePixelBuffer())
        XCTAssertNil(SimCamFrameCheck.problem(with: pb))
        XCTAssertNotNil(CVPixelBufferGetIOSurface(pb), "sink frames must be IOSurface-backed")
    }

    func testWrongSizeIsRejected() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, nil, &pb)
        XCTAssertNotNil(SimCamFrameCheck.problem(with: try XCTUnwrap(pb)))
    }

    func testWrongFormatIsRejected() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, kSimCamFrameWidth, kSimCamFrameHeight,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb
        )
        XCTAssertNotNil(SimCamFrameCheck.problem(with: try XCTUnwrap(pb)))
    }

    // MARK: Sample buffer wrapping

    func testSampleBufferMatchesPixelBuffer() throws {
        let pb = try XCTUnwrap(FrameRaster.makePixelBuffer())
        let sb = try XCTUnwrap(FrameRaster.makeSampleBuffer(pb))
        XCTAssertTrue(CMSampleBufferDataIsReady(sb))
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sb))
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(Int(dims.width), kSimCamFrameWidth)
        XCTAssertEqual(Int(dims.height), kSimCamFrameHeight)
        XCTAssertTrue(CMSampleBufferGetPresentationTimeStamp(sb).seconds > 0)
    }

    // MARK: Sink client without an extension

    func testEnqueueBeforeAttachReportsSinkClosed() throws {
        let client = CMIOSinkClient()
        let pb = try XCTUnwrap(FrameRaster.makePixelBuffer())
        XCTAssertEqual(client.enqueue(pb), .sinkClosed)
        XCTAssertFalse(client.isAttached)
    }

    func testEnqueueRejectsWrongGeometryBeforeTouchingTheQueue() throws {
        let client = CMIOSinkClient()
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, nil, &pb)
        if case .rejected = client.enqueue(try XCTUnwrap(pb)) {
        } else {
            XCTFail("wrong-size frame must be rejected")
        }
    }

    func testAttachFailsCleanlyWhenDeviceAbsent() {
        // Devices are enumerated for real here; the virtual camera is not
        // expected on CI. Either outcome must be a clean error, never a crash.
        let client = CMIOSinkClient()
        do {
            try client.attach()
            XCTAssertTrue(client.isAttached)
        } catch let error as CMIOSinkClientError {
            XCTAssertTrue(error == .deviceNotFound || error == .streamsNotFound)
        } catch {
            XCTFail("unexpected error type \(error)")
        }
        client.detach()
        XCTAssertFalse(client.isAttached)
    }

    func testReadStatusWithoutAttachThrows() {
        let client = CMIOSinkClient()
        XCTAssertThrowsError(try client.readStatus())
        XCTAssertThrowsError(try client.setSourceKind(.image))
        XCTAssertThrowsError(try client.openSink())
    }

    // MARK: Raster helpers

    func testAspectFitLetterboxesPortrait() {
        let rect = FrameRaster.aspectFitRect(for: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(rect.height, 720, accuracy: 0.001)
        XCTAssertEqual(rect.width, 405, accuracy: 0.001)
        XCTAssertEqual(rect.midX, 640, accuracy: 0.001)
    }

    func testAspectFitPillarboxesWide() {
        let rect = FrameRaster.aspectFitRect(for: CGSize(width: 3840, height: 1080))
        XCTAssertEqual(rect.width, 1280, accuracy: 0.001)
        XCTAssertEqual(rect.height, 360, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 360, accuracy: 0.001)
    }

    func testAspectFitHandlesDegenerateSize() {
        let rect = FrameRaster.aspectFitRect(for: .zero)
        XCTAssertEqual(rect.width, CGFloat(kSimCamFrameWidth))
        XCTAssertEqual(rect.height, CGFloat(kSimCamFrameHeight))
    }

    func testRasterProducesCanonicalFrame() throws {
        let pb = try XCTUnwrap(FrameRaster.render(background: CGColor(red: 0, green: 0, blue: 0, alpha: 1)) { _ in })
        XCTAssertNil(SimCamFrameCheck.problem(with: pb))
    }

    func testQRRendererProducesValidWhiteFrame() throws {
        let pb = try XCTUnwrap(QRRenderer.render(payload: "https://example.com"))
        XCTAssertNil(SimCamFrameCheck.problem(with: pb))
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pb)).assumingMemoryBound(to: UInt8.self)
        // Top-left pixel is background: B, G, R all 0xFF.
        XCTAssertEqual(base[0], 0xFF)
        XCTAssertEqual(base[1], 0xFF)
        XCTAssertEqual(base[2], 0xFF)
    }

    func testQRRendererRejectsOversizedPayload() {
        // QR max capacity is ~2953 bytes at level M; Core Image returns nil above that.
        let huge = String(repeating: "x", count: 5000)
        XCTAssertNil(QRRenderer.render(payload: huge))
    }
}
