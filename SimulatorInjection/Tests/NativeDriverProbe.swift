import UIKit
@preconcurrency import AVFoundation

// Compiled with the caller's actual Media sources, not a copy or replacement recorder.
@main
@MainActor
final class NativeDriverProbe: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let driver = NativeVideoCaptureDriver()
    private let label = UILabel()
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let view = UIViewController()
        view.view.backgroundColor = .black
        label.frame = CGRect(x: 24, y: 70, width: 340, height: 90)
        label.textColor = .white
        label.numberOfLines = 0
        label.text = "Native Small Hello driver\nPreparing recording"
        view.view.addSubview(label)
        let preview = AVCaptureVideoPreviewLayer()
        preview.frame = CGRect(x: 20, y: 180, width: 350, height: 450)
        preview.videoGravity = .resizeAspect
        driver.previewSource.connect(to: preview)
        view.view.layer.addSublayer(preview)
        window.rootViewController = view
        window.makeKeyAndVisible()
        self.window = window
        Task {
            try? await Task.sleep(for: .seconds(20))
            finish("FAIL native driver watchdog", success: false)
        }
        Task {
            do {
                try await Task.sleep(for: .seconds(1))
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                if ProcessInfo.processInfo.environment["NATIVE_CANCEL"] == "1" {
                    let url = documents.appendingPathComponent("native-cancel.mov")
                    try? FileManager.default.removeItem(at: url)
                    let start = Task { try await driver.beginRecording(to: url) }
                    try await Task.sleep(for: .milliseconds(30))
                    await driver.stopRecording()
                    do {
                        let completion = try await start.value
                        try await completion.value
                    } catch { print("NATIVE cancellation settled: \(error)") }
                    let retryURL = documents.appendingPathComponent("native-cancel-retry.mov")
                    try? FileManager.default.removeItem(at: retryURL)
                    let retry = try await driver.beginRecording(to: retryURL)
                    try await Task.sleep(for: .seconds(1))
                    await driver.stopRecording()
                    try await retry.value
                    let retryAsset = AVURLAsset(url: retryURL)
                    guard try await retryAsset.loadTracks(withMediaType: .video).count == 1,
                          try await retryAsset.loadTracks(withMediaType: .audio).count == 1 else { throw MediaError.unusableVideo }
                    finish("PASS exact driver startup cancellation and subsequent recording", success: true)
                    return
                }
                for take in 1...2 {
                    let url = documents.appendingPathComponent("native-\(take).mov")
                    try? FileManager.default.removeItem(at: url)
                    label.text = "Native Small Hello driver\nRecording take \(take)"
                    print("NATIVE requesting take \(take)")
                    let completion = try await driver.beginRecording(to: url)
                    print("NATIVE started take \(take)")
                    if take == 1 { try "ready".write(to: documents.appendingPathComponent("native-recording-ready"), atomically: true, encoding: .utf8) }
                    try await Task.sleep(for: .seconds(2))
                    await driver.stopRecording()
                    print("NATIVE stop requested take \(take)")
                    try await completion.value
                    let asset = AVURLAsset(url: url)
                    let video = try await asset.loadTracks(withMediaType: .video)
                    let audio = try await asset.loadTracks(withMediaType: .audio)
                    let duration = try await asset.load(.duration).seconds
                    guard video.count == 1, audio.count == 1, duration > 1.5 else {
                        print("NATIVE unexpected short capture duration=\(duration)")
                        throw MediaError.unusableVideo
                    }
                    print("NATIVE finalized \(url.path)")
                }
                label.text = "Native Small Hello driver\nReplaying finalized video + audio"
                preview.removeFromSuperlayer()
                let playbackAudio = AudioSessionLease()
                try playbackAudio.activateForPlayback()
                defer { playbackAudio.restore() }
                let player = AVPlayer(url: documents.appendingPathComponent("native-2.mov"))
                player.isMuted = true // Decode playback without playing a fixture into the user's speakers.
                self.player = player
                let layer = AVPlayerLayer(player: player)
                layer.frame = preview.frame
                view.view.layer.addSublayer(layer)
                self.playerLayer = layer
                player.play()
                let playbackDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                while (player.currentTime().seconds <= 0.2 || !layer.isReadyForDisplay) && ContinuousClock.now < playbackDeadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                print("NATIVE replay time=\(player.currentTime().seconds) readyForDisplay=\(layer.isReadyForDisplay) error=\(String(describing: player.error))")
                guard player.currentTime().seconds > 0.2, layer.isReadyForDisplay else { throw MediaError.unusableVideo }
                try "ready".write(to: documents.appendingPathComponent("native-replay-ready"), atomically: true, encoding: .utf8)
                try await Task.sleep(for: .seconds(2))
                finish("PASS exact native driver two takes and replay", success: true)
            } catch { finish("FAIL native driver \(error)", success: false) }
        }
        return true
    }

    private func finish(_ message: String, success: Bool) {
        print(message)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? message.write(to: documents.appendingPathComponent("native-result.txt"), atomically: true, encoding: .utf8)
        exit(success ? 0 : 1)
    }
}
