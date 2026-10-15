//
//  App.swift
//  SimulatorCamera (container app)
//
//  SwiftUI entry point. Hosts ExtensionController (system extension state),
//  CameraLink (connection to the running extension's sink stream),
//  SourceManager (active frame source). Single window UI exposes the 5
//  sources: test pattern, Mac camera, video file, image, QR code.
//

import SwiftUI

@main
struct SimulatorCameraApp: App {
    @State private var extensionController = ExtensionController()
    @State private var cameraLink: CameraLink
    @State private var sourceManager: SourceManager

    init() {
        let link = CameraLink()
        _cameraLink = State(initialValue: link)
        _sourceManager = State(initialValue: SourceManager(link: link))
    }

    var body: some Scene {
        WindowGroup("SimulatorCamera") {
            MainView()
                .environment(extensionController)
                .environment(cameraLink)
                .environment(sourceManager)
                .frame(minWidth: 540, minHeight: 520)
                .task {
                    extensionController.check()
                    cameraLink.connect()
                }
        }
        .windowResizability(.contentSize)
    }
}
