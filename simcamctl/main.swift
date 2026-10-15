//
//  main.swift
//  simcamctl
//
//  Command-line control for SimulatorCamera. Talks to the running extension
//  via CoreMediaIO. Subcommands match SimCam's simcamctl shape:
//
//    simcamctl status
//    simcamctl ping
//    simcamctl set-source --pattern
//    simcamctl set-source --qr "PAYLOAD"
//    simcamctl set-source --image /path/to/file.png
//
//  Exit codes: 0 success, 1 generic error, 2 extension unreachable, 3 invalid args.
//

import Foundation

let args = CommandLine.arguments
let progName = (args.first as NSString?)?.lastPathComponent ?? "simcamctl"

func usage() -> Never {
    let helpText = """
    \(progName) — control SimulatorCamera from the command line

    USAGE:
      \(progName) <subcommand> [options]

    SUBCOMMANDS:
      status                       Print extension state + frame stats
      ping                         Verify the virtual camera is registered
      set-source --pattern         Use the built-in test pattern
      set-source --qr "PAYLOAD"    Generate + stream a QR code
      set-source --image PATH      Stream a static PNG/JPG file
      feed --pattern|--qr TEXT|--image PATH|--camera [--seconds N]
                                   Stream frames to iOS Simulator apps launched
                                   with SimulatorInjection (no extension needed)
      help                         Show this help

    EXIT CODES:
      0    success
      1    generic error
      2    extension not reachable (not activated?)
      3    invalid arguments

    The container app must be installed and the extension activated. Frame pushes
    (--qr, --image) open the camera's sink stream and may trigger a one-time
    camera-access prompt for your terminal. If status
    shows the extension is inactive, run /Applications/SimulatorCamera.app to
    activate it.
    """
    FileHandle.standardError.write(Data(helpText.utf8))
    FileHandle.standardError.write(Data("\n".utf8))
    exit(3)
}

if args.count < 2 { usage() }

let subcommand = args[1]

if subcommand == "feed" {
    guard args.count >= 3 else { usage() }
    var seconds: Double?
    if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count { seconds = Double(args[i + 1]) }
    let value = args.count >= 4 ? args[3] : ""
    let source: FeedCommand.Source
    switch args[2] {
    case "--pattern": source = .pattern
    case "--camera": source = .camera
    case "--qr" where !value.isEmpty: source = .qr(value)
    case "--image" where !value.isEmpty: source = .image(value)
    default: usage()
    }
    FeedCommand().run(source, seconds: seconds)
}

let cli = SimCamCLIClient()

switch subcommand {
case "help", "-h", "--help":
    usage()

case "ping":
    cli.runPing()

case "status":
    cli.runStatus()

case "set-source":
    if args.count < 3 { usage() }
    let flag = args[2]
    switch flag {
    case "--pattern":
        cli.runSetSource(.testPattern)
    case "--qr":
        guard args.count >= 4 else {
            FileHandle.standardError.write(Data("error: --qr requires a payload string\n".utf8))
            exit(3)
        }
        cli.runSetQR(payload: args[3])
    case "--image":
        guard args.count >= 4 else {
            FileHandle.standardError.write(Data("error: --image requires a file path\n".utf8))
            exit(3)
        }
        cli.runSetImage(path: args[3])
    default:
        FileHandle.standardError.write(Data("error: unknown set-source flag '\(flag)'\n".utf8))
        usage()
    }

default:
    FileHandle.standardError.write(Data("error: unknown subcommand '\(subcommand)'\n".utf8))
    usage()
}
