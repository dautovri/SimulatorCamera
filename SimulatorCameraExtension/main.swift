//
//  main.swift
//  SimulatorCameraExtension
//
//  Entry point for the Camera Extension. Starts the CMIOExtensionProvider,
//  which registers the virtual camera (source stream), its sink stream for
//  the container app, and the custom control properties. Runs forever as a
//  system extension daemon.
//

import Foundation
import CoreMediaIO

let providerSource = SimulatorCameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
