//
//  VideoFileSource.swift
//  SimulatorCamera
//
//  AVAssetReader against a local video file. Decodes BGRA frames at the
//  asset's native frame rate, loops at EOF. Honors preferredTransform so
//  iPhone-shot portrait videos render upright, and letterboxes everything
//  into the canonical 1280x720 frame.
//

import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import OSLog

final class VideoFileSource: FrameSource {

    let kind: SimCamSourceKind = .videoFile
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let url: URL
    private let log = Logger(subsystem: "com.dautov.SimulatorCamera", category: "video-file")
    private let normalizer = FrameNormalizer()
    private var task: Task<Void, Never>?

    /// Everything we need to open a reader on the asset. Loaded once in
    /// start() so an unreadable file fails the switch instead of silently
    /// producing nothing.
    private struct Track {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let transform: CGAffineTransform
        let frameInterval: Double
    }

    init(url: URL) {
        self.url = url
    }

    func start() async throws {
        task?.cancel()
        let track = try await loadTrack()
        task = Task.detached(priority: .userInitiated) { [self] in
            await self.runLoop(track)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        onFrame = nil
        log.info("VideoFileSource stopped")
    }

    // MARK: - Loading

    private func loadTrack() async throws -> Track {
        let asset = AVURLAsset(url: url)
        let (isPlayable, hasProtected) = try await asset.load(.isPlayable, .hasProtectedContent)
        guard isPlayable else {
            throw FrameSourceError.invalidInput("\(url.lastPathComponent) is not playable.")
        }
        guard !hasProtected else {
            throw FrameSourceError.invalidInput("\(url.lastPathComponent) is DRM-protected.")
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FrameSourceError.invalidInput("\(url.lastPathComponent) has no video track.")
        }
        let (nominalFPS, transform) = try await track.load(.nominalFrameRate, .preferredTransform)
        let fps = nominalFPS > 1 ? Double(nominalFPS) : Double(kSimCamFrameRate)
        return Track(asset: asset, track: track, transform: transform, frameInterval: 1.0 / fps)
    }

    // MARK: - Decode loop

    private func runLoop(_ track: Track) async {
        var loopCount = 0
        var consecutiveEmptyPasses = 0

        while !Task.isCancelled {
            let reader: AVAssetReader
            let output: AVAssetReaderTrackOutput
            do {
                reader = try AVAssetReader(asset: track.asset)
            } catch {
                log.error("AVAssetReader init failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            output = AVAssetReaderTrackOutput(
                track: track.track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                log.error("reader can't add output")
                return
            }
            reader.add(output)
            guard reader.startReading() else {
                log.error("reader failed to start: \(reader.error?.localizedDescription ?? "unknown", privacy: .public)")
                return
            }
            // Cancelling the reader releases its decoder threads immediately
            // instead of when the object happens to be deallocated.
            defer { reader.cancelReading() }

            var framesThisPass = 0
            let passStart = ContinuousClock.now

            while !Task.isCancelled, reader.status == .reading {
                guard let sb = output.copyNextSampleBuffer() else { break }
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }

                let pts = max(0, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)))
                framesThisPass += 1

                if let frame = normalizer.canonicalize(pb, transform: track.transform) {
                    onFrame?(frame)
                }

                // Pace against the wall clock using the sample's own PTS so
                // decode jitter doesn't accumulate as drift.
                let target = passStart + .seconds(pts + track.frameInterval)
                let wait = ContinuousClock.now.duration(to: target)
                if wait > .zero {
                    try? await Task.sleep(for: wait)
                } else {
                    await Task.yield()
                }
            }

            if Task.isCancelled { return }

            if reader.status == .failed {
                log.error("reader failed mid-stream: \(reader.error?.localizedDescription ?? "unknown", privacy: .public)")
                return
            }

            // A pass that decoded nothing means the file is unreadable; bail
            // instead of spinning on reader creation forever.
            if framesThisPass == 0 {
                consecutiveEmptyPasses += 1
                if consecutiveEmptyPasses >= 3 {
                    log.error("no decodable frames in \(self.url.lastPathComponent, privacy: .public); stopping")
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            consecutiveEmptyPasses = 0
            loopCount += 1
            log.info("video EOF, looping (count=\(loopCount))")
        }
    }
}
