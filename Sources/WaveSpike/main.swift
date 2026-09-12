//
//  wave-spike
//
//  The smallest executable that proves Wave's entire audio chain on a real
//  Mac:
//
//      application process
//        -> process tap (muted at source)
//        -> aggregate device
//        -> IO callback
//        -> software gain
//        -> selected physical output
//
//  It deliberately shares the exact production components — ProcessTapController,
//  RealtimeRenderer, the same C control block — rather than reimplementing a
//  simplified version, so a green spike is evidence about the shipping code and
//  not about a parallel toy.
//
//  Run it from inside the built app bundle so it inherits Wave's code signature
//  and Info.plist, which is what macOS keys the audio-capture privilege to:
//
//      ./build/Wave.app/Contents/MacOS/wave-spike list
//      ./build/Wave.app/Contents/MacOS/wave-spike route --app Music --seconds 30
//

import Foundation
import CoreAudio
import AudioToolbox
import WaveCore
import WaveAudio

// MARK: - Signal handling

/// Set from a signal handler, so it must be a plain C-compatible global that a
/// capture-less C function pointer can reach.
var waveSpikeShouldStop: sig_atomic_t = 0

func installSignalHandlers() {
    signal(SIGINT) { _ in waveSpikeShouldStop = 1 }
    signal(SIGTERM) { _ in waveSpikeShouldStop = 1 }
}

// MARK: - Output helpers

func out(_ text: String = "") { print(text) }
func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + text + "\n").utf8))
    exit(1)
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

func bar(_ value: Float, width: Int = 24) -> String {
    let normalised = MeterBallistics.normalised(amplitude: value)
    let filled = Int((normalised * Float(width)).rounded())
    return String(repeating: "#", count: max(0, min(width, filled)))
        + String(repeating: ".", count: max(0, width - filled))
}

// MARK: - Argument parsing

struct Arguments {
    var command: String = "list"
    var app: String?
    var device: String?
    var volume: Float = 1.0
    var seconds: Double = 30
    var sweep = true
    var mute = false

    static func parse(_ raw: [String]) -> Arguments {
        var arguments = Arguments()
        var index = 0
        if let first = raw.first, !first.hasPrefix("--") {
            arguments.command = first
            index = 1
        }
        while index < raw.count {
            let flag = raw[index]
            func value() -> String? {
                guard index + 1 < raw.count else { return nil }
                index += 1
                return raw[index]
            }
            switch flag {
            case "--app": arguments.app = value()
            case "--device": arguments.device = value()
            case "--volume": arguments.volume = Float(value() ?? "1") ?? 1
            case "--seconds": arguments.seconds = Double(value() ?? "30") ?? 30
            case "--no-sweep": arguments.sweep = false
            case "--mute": arguments.mute = true
            case "--help", "-h": arguments.command = "help"
            default: break
            }
            index += 1
        }
        return arguments
    }
}

// MARK: - Shared setup

func waitForDiscovery(_ devices: AudioDeviceRegistry, _ processes: AudioProcessDiscovery) {
    devices.start()
    processes.start()
    // Both publish asynchronously on their own queues; a short settle is
    // simpler and more honest here than plumbing completion handlers into a
    // diagnostic tool.
    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline, devices.devices.isEmpty || processes.apps.isEmpty {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

func printUsage() {
    out("""
        wave-spike - proves Wave's per-app capture and routing chain

        Commands:
          list                       Show audio processes and output devices
          permission                 Report system audio recording status
          route --app <name>         Capture one app, apply gain, render to a device
          help

        Options for `route`:
          --app <name|bundle id>     Required. Matched case-insensitively.
          --device <name|uid>        Destination. Defaults to the system output.
          --volume <0.0-1.0>         Fader position. Default 1.0
          --seconds <n>              How long to run. Default 30
          --mute                     Route but hold the fader at silence
          --no-sweep                 Hold --volume instead of sweeping it

        By default `route` sweeps the fader 100% -> 25% -> 100% so the gain
        change is audible, and prints live pre-gain and post-gain meters.
        """)
}

// MARK: - Commands

func commandList() {
    let devices = AudioDeviceRegistry()
    let processes = AudioProcessDiscovery()
    waitForDiscovery(devices, processes)

    out("Output devices")
    out("--------------")
    if devices.devices.isEmpty { out("  (none)") }
    for device in devices.devices {
        let marker = device.isSystemDefault ? " *default*" : ""
        out("  \(device.name)\(marker)")
        out("      uid=\(device.uid)  channels=\(device.outputChannelCount)  transport=\(device.transport.rawValue)")
    }

    out()
    out("Audio processes (grouped by application)")
    out("----------------------------------------")
    if processes.apps.isEmpty { out("  (none)") }
    for app in processes.apps {
        let marker = app.isProducingOutput ? "PLAYING" : "idle   "
        out("  [\(marker)] \(app.displayName)")
        out("      key=\(app.key.rawValue)  pids=\(app.pids.map(String.init).joined(separator: ","))")
    }

    devices.stop()
    processes.stop()
}

func commandPermission() {
    let permissions = PermissionController()
    let status = permissions.refresh()
    out("System audio recording: \(status.rawValue)")
    switch status {
    case .authorized:
        out("Wave can capture other applications' audio.")
    case .denied:
        out(PermissionController.manualInstructions)
    case .undetermined:
        out("macOS has not been asked yet, or Wave cannot tell without starting audio.")
        out("Run `route` and watch the pre-gain meter: a process that is playing but")
        out("shows a flat pre-gain meter means capture is being withheld.")
    }
}

func commandRoute(_ arguments: Arguments) {
    guard let appQuery = arguments.app else { fail("route requires --app") }

    let diagnostics = Diagnostics.shared
    let devices = AudioDeviceRegistry(diagnostics: diagnostics)
    let processes = AudioProcessDiscovery(diagnostics: diagnostics)
    let permissions = PermissionController(diagnostics: diagnostics)
    waitForDiscovery(devices, processes)

    let permissionStatus = permissions.refresh()
    out("System audio recording: \(permissionStatus.rawValue)")
    if permissionStatus == .denied {
        out(PermissionController.manualInstructions)
        fail("refusing to present a working-looking route without capture permission")
    }

    // Resolve the application.
    let needle = appQuery.lowercased()
    guard let app = processes.apps.first(where: {
        $0.displayName.lowercased().contains(needle)
            || $0.key.rawValue.lowercased().contains(needle)
            || ($0.bundleIdentifier?.lowercased().contains(needle) ?? false)
    }) else {
        fail("no audio process matched '\(appQuery)'. Run `wave-spike list` to see the options.")
    }

    // Resolve the destination.
    let destination: OutputDeviceSnapshot
    if let query = arguments.device?.lowercased() {
        guard let match = devices.devices.first(where: {
            $0.name.lowercased().contains(query) || $0.uid.lowercased() == query
        }) else {
            fail("no output device matched '\(arguments.device ?? "")'.")
        }
        destination = match
    } else {
        guard let fallback = devices.devices.first(where: \.isSystemDefault) ?? devices.devices.first else {
            fail("no usable output device.")
        }
        destination = fallback
    }

    out("Application : \(app.displayName)  (\(app.processObjectIDs.count) process object(s))")
    out("Destination : \(destination.name)  [\(destination.uid)]")
    out("Playing?    : \(app.isProducingOutput ? "yes" : "no - start playback for a meaningful result")")
    out()

    guard let controlBlock = RealtimeControlBlock() else { fail("could not allocate the control block") }
    let tapController = ProcessTapController(diagnostics: diagnostics)

    let prepared: ProcessTapController.Prepared
    do {
        prepared = try tapController.prepare(.init(processObjectIDs: app.processObjectIDs,
                                                   destinationDeviceUID: destination.uid,
                                                   label: app.displayName,
                                                   muteOriginalOutput: true))
    } catch {
        controlBlock.dispose()
        fail("\((error as? CustomStringConvertible)?.description ?? error.localizedDescription)")
    }

    out("Tap         : #\(prepared.tapID)  uuid=\(prepared.tapUUID.uuidString)")
    out("Aggregate   : #\(prepared.aggregateDeviceID)  buffer=\(prepared.bufferFrameSize) frames")
    out("Format      : \(prepared.plan.input.channelCount)ch in -> \(prepared.plan.output.channelCount)ch out "
        + "@ \(Int(prepared.plan.output.sampleRate)) Hz "
        + "(in \(prepared.plan.input.isInterleaved ? "interleaved" : "planar"), "
        + "out \(prepared.plan.output.isInterleaved ? "interleaved" : "planar"))")
    out()

    controlBlock.isActive = true
    controlBlock.targetGain = GainResolver.targetGain(position: arguments.volume, isMuted: arguments.mute)

    let renderer: RealtimeRenderer
    do {
        renderer = try RealtimeRenderer(deviceID: prepared.aggregateDeviceID,
                                        plan: prepared.plan,
                                        controlBlock: controlBlock,
                                        diagnostics: diagnostics)
        try renderer.start()
    } catch {
        tapController.tearDown()
        controlBlock.dispose()
        fail("\((error as? CustomStringConvertible)?.description ?? error.localizedDescription)")
    }

    out("Routing. The application is now muted on its normal output and is being")
    out("rendered through Wave's gain stage instead. Press Ctrl-C to stop.")
    out()
    out("   time  fader  pre-gain (tapped)          post-gain (rendered)")

    installSignalHandlers()

    var watchdog = SilenceWatchdog()
    var blockedReported = false
    let start = Date()

    while waveSpikeShouldStop == 0, Date().timeIntervalSince(start) < arguments.seconds {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        let elapsed = Date().timeIntervalSince(start)

        // Sweeping the fader is the point of the spike: it is what makes
        // "the app got quieter" something you can hear rather than infer.
        var position = arguments.volume
        if arguments.sweep && !arguments.mute {
            let phase = elapsed.truncatingRemainder(dividingBy: 12) / 12
            position = phase < 0.5
                ? Float(1.0 - 1.5 * phase)          // 1.00 -> 0.25
                : Float(0.25 + 1.5 * (phase - 0.5)) // 0.25 -> 1.00
        }
        controlBlock.targetGain = GainResolver.targetGain(position: position, isMuted: arguments.mute)

        let peaks = controlBlock.drainPeaks()
        let inputPeak = controlBlock.drainInputPeak()
        processes.refreshNow()
        let claimsActive = processes.app(for: app.key)?.isProducingOutput ?? false

        let stamp = String(format: "%5.1f", elapsed)
        let percent = String(VolumeCurve.percent(forPosition: position))
        out("  \(stamp)s  " + percent.leftPadded(to: 3) + "%  "
            + bar(inputPeak) + "  " + bar(max(peaks.left, peaks.right)))

        switch watchdog.observe(peak: inputPeak, sourceClaimsActive: claimsActive) {
        case .captureAppearsBlocked where !blockedReported:
            blockedReported = true
            out()
            out("!! The tap is delivering pure silence while macOS reports this app as playing.")
            out("!! That is what a denied System Audio Recording privilege looks like: every")
            out("!! Core Audio call returned success and the buffers are empty.")
            out(PermissionController.manualInstructions)
            out()
        default:
            break
        }
    }

    out()
    out("Stopping. Restoring normal playback...")

    // The production teardown order, exercised exactly as the engine does it.
    controlBlock.isActive = false
    renderer.stop()
    tapController.tearDown()

    let statistics = controlBlock.statistics()
    controlBlock.dispose()
    devices.stop()
    processes.stop()

    out()
    out("Render statistics")
    out("  buffers rendered : \(statistics.buffersRendered)")
    out("  frames rendered  : \(statistics.framesRendered)")
    out("  silent buffers   : \(statistics.silentBuffers)")
    out("  underruns        : \(statistics.underruns)")
    out("  clamped samples  : \(statistics.clampedSamples)")
    out()
    if statistics.buffersRendered == 0 {
        out("VERDICT: the IO callback never fired. The route did not work.")
    } else if statistics.silentBuffers == statistics.buffersRendered {
        out("VERDICT: the callback ran but every tapped buffer was silent.")
        out("         Either the app produced no audio, or capture is being withheld.")
    } else {
        let audible = statistics.buffersRendered - statistics.silentBuffers
        out("VERDICT: captured and rendered \(audible) buffer(s) containing audio.")
        out("         The tap is destroyed, so \(app.displayName) is back on its normal output.")
    }
}

// MARK: - Entry point

let arguments = Arguments.parse(Array(CommandLine.arguments.dropFirst()))
switch arguments.command {
case "list": commandList()
case "permission": commandPermission()
case "route": commandRoute(arguments)
case "help": printUsage()
default:
    printUsage()
    exit(2)
}
