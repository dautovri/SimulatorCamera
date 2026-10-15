//
//  FrameStore.swift
//  SimulatorCamera
//
//  Publishes the newest frame to /private/tmp/SimulatorCamera/frame.bin, where
//  the simulator injection library (SimulatorInjection/SimCamInject.m) reads
//  it. This is how frames reach iOS Simulator apps: the Simulator's own
//  capture stack has no host-camera path (verified on Xcode 27, iOS 26.5/27),
//  so a CMIO virtual camera alone is invisible to simulator apps.
//  Layout must match SimulatorInjection/SCFrameStore.h.
//

import CoreVideo
import Foundation

final class FrameStore: @unchecked Sendable {
    static let directory = "/private/tmp/SimulatorCamera"
    static let path = directory + "/frame.bin"
    static let magic: UInt32 = 0x3146_4353
    static let headerSize = 64
    static let maxWidth = 1920, maxHeight = 1080
    static let fileSize = headerSize + maxWidth * maxHeight * 4

    private var base: UnsafeMutableRawPointer?
    private var seq: UInt64 = 0
    private let lock = NSLock()

    init() {}

    deinit {
        if let base { munmap(base, Self.fileSize) }
    }

    private func mapIfNeeded() -> UnsafeMutableRawPointer? {
        if let base { return base }
        try? FileManager.default.createDirectory(atPath: Self.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755])
        let fd = open(Self.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard ftruncate(fd, off_t(Self.fileSize)) == 0 else { return nil }
        let p = mmap(nil, Self.fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let p, p != MAP_FAILED else { return nil }
        base = p
        // Continue from whatever sequence a previous writer left, kept even.
        let old = p.load(fromByteOffset: 24, as: UInt64.self)
        seq = old &+ (old & 1)
        return p
    }

    /// Write one BGRA frame. Frames larger than 1920x1080 are skipped.
    func write(width: Int, height: Int, bytesPerRow: Int, bgra: UnsafeRawPointer, sourceKind: UInt32, time: Double) {
        guard width > 0, height > 0, width <= Self.maxWidth, height <= Self.maxHeight,
              bytesPerRow >= width * 4, bytesPerRow * height <= Self.maxWidth * Self.maxHeight * 4 else { return }
        lock.lock(); defer { lock.unlock() }
        guard let p = mapIfNeeded() else { return }
        seq &+= 1 // odd: write in progress
        p.storeBytes(of: seq, toByteOffset: 24, as: UInt64.self)
        OSMemoryBarrier()
        p.storeBytes(of: Self.magic, toByteOffset: 0, as: UInt32.self)
        p.storeBytes(of: UInt32(1), toByteOffset: 4, as: UInt32.self)
        p.storeBytes(of: UInt32(width), toByteOffset: 8, as: UInt32.self)
        p.storeBytes(of: UInt32(height), toByteOffset: 12, as: UInt32.self)
        p.storeBytes(of: UInt32(bytesPerRow), toByteOffset: 16, as: UInt32.self)
        p.storeBytes(of: sourceKind, toByteOffset: 20, as: UInt32.self)
        p.storeBytes(of: time, toByteOffset: 32, as: Double.self)
        memcpy(p + Self.headerSize, bgra, bytesPerRow * height)
        OSMemoryBarrier()
        seq &+= 1 // even: complete
        p.storeBytes(of: seq, toByteOffset: 24, as: UInt64.self)
    }

    func write(_ pixelBuffer: CVPixelBuffer, sourceKind: UInt32) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        // Wall clock: readers drop frames more than 3 s old.
        write(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
              bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), bgra: base,
              sourceKind: sourceKind, time: Date().timeIntervalSince1970)
    }
}
