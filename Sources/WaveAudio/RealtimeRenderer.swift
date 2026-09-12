import Foundation
import CoreAudio
import AudioToolbox
import WaveCore
import WaveRTSupport

/// Storage the render callback reads. Plain old data, allocated once.
///
/// Nothing reachable from here is a Swift class, so the callback performs no
/// retain, release, or exclusivity check. Nothing here is resized while the
/// callback is live, so the callback never allocates.
struct RenderContextStorage {
    /// `WaveRTBlock *` — the lock-free channel to the UI.
    var block: OpaquePointer
    /// Per-sample gain ramp state. Lives here so it survives between buffers.
    var smoother: GainSmoother
    /// True once the first buffer has been rendered, so the very first fader
    /// value is applied without a fade-in from zero.
    var hasRendered: Bool

    var inputChannels: Int32
    var outputChannels: Int32

    /// `outputChannels` entries describing how each output channel is built.
    var taps: UnsafeMutablePointer<ChannelTap>
    /// Scratch tables refilled at the start of every callback. Sized at setup
    /// so filling them costs no allocation.
    var sourceBase: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    var sourceStride: UnsafeMutablePointer<Int32>
    var destinationBase: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    var destinationStride: UnsafeMutablePointer<Int32>
}

/// The audio callback.
///
/// Everything this function is allowed to do, it does: read two atomics, walk
/// two buffer lists, multiply floats, write two atomics. Everything it must not
/// do — allocate, lock, log, call Objective-C, touch Swift objects, resolve a
/// dictionary, format a string — it does not do, and the types above exist to
/// make doing any of it awkward.
@inline(__always)
func waveRender(_ context: UnsafeMutablePointer<RenderContextStorage>,
                _ input: UnsafePointer<AudioBufferList>,
                _ output: UnsafeMutablePointer<AudioBufferList>) {

    let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
    let block = context.pointee.block

    // Map the destination buffers to per-channel base pointers and strides.
    // Doing it this way handles interleaved and planar layouts with the same
    // inner loop, instead of branching on the layout per sample.
    var outputChannelCount = 0
    let maxOutput = Int(context.pointee.outputChannels)
    for buffer in outputBuffers {
        let channels = Int(buffer.mNumberChannels)
        guard let data = buffer.mData, channels > 0 else { continue }
        let floats = data.assumingMemoryBound(to: Float.self)
        for channel in 0..<channels {
            guard outputChannelCount < maxOutput else { break }
            context.pointee.destinationBase[outputChannelCount] = floats + channel
            context.pointee.destinationStride[outputChannelCount] = Int32(channels)
            outputChannelCount += 1
        }
    }
    guard outputChannelCount > 0 else { return }

    let outputFrames = waveFrameCount(outputBuffers)
    guard outputFrames > 0 else { return }

    // A parked route, or one whose destination has gone, emits silence rather
    // than whatever the previous client left in the buffer.
    let isActive = WaveRTBlockIsActive(block)

    var inputChannelCount = 0
    var inputFrames = 0
    if isActive {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let maxInput = Int(context.pointee.inputChannels)
        for buffer in inputBuffers {
            let channels = Int(buffer.mNumberChannels)
            guard let data = buffer.mData, channels > 0 else { continue }
            let floats = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<channels {
                guard inputChannelCount < maxInput else { break }
                context.pointee.sourceBase[inputChannelCount] = floats + channel
                context.pointee.sourceStride[inputChannelCount] = Int32(channels)
                inputChannelCount += 1
            }
        }
        inputFrames = waveFrameCount(inputBuffers)
    }

    // Never read more frames than the tap actually delivered. Inside one
    // aggregate device the two sides run on the same clock and these agree, but
    // trusting that would turn any disagreement into a read past the end of the
    // input buffer on the audio thread.
    let renderFrames = min(outputFrames, inputFrames)

    guard isActive, inputChannelCount > 0, renderFrames > 0 else {
        waveSilence(context, channels: outputChannelCount, from: 0, to: outputFrames)
        WaveRTBlockAddCounter(block, WaveRTCounterBuffers, 1)
        if isActive { WaveRTBlockAddCounter(block, WaveRTCounterUnderruns, 1) }
        return
    }
    if renderFrames < outputFrames {
        WaveRTBlockAddCounter(block, WaveRTCounterFormatMismatches, 1)
    }

    // The fader value is read once per buffer; the ramp towards it advances per
    // sample inside the loop, which is what stops a fader move from stepping
    // the waveform and clicking.
    let target = WaveRTBlockTargetGain(block)
    context.pointee.smoother.setTarget(target)
    if !context.pointee.hasRendered {
        // First buffer of a route: start at the right level instead of fading
        // in from silence.
        context.pointee.smoother.snap(to: target)
        context.pointee.hasRendered = true
    }

    var inputPeak: Float = 0
    var clamped: UInt64 = 0
    var meterPeak0: Float = 0
    var meterPeak1: Float = 0

    // Frames are the outer loop because the gain ramp must advance exactly once
    // per frame and be shared by every channel; stepping it per channel would
    // detune the ramp across a stereo pair. The cost is touching each channel's
    // buffer once per frame rather than streaming through one at a time, which
    // is irrelevant at the two channels a stereo mixdown tap produces.
    var smoother = context.pointee.smoother
    for frame in 0..<renderFrames {
        let gain = smoother.advance()

        for outputChannel in 0..<outputChannelCount {
            let tap = context.pointee.taps[outputChannel]
            guard let destination = context.pointee.destinationBase[outputChannel] else { continue }

            var sample: Float = 0
            let sourceA = Int(tap.sourceA)
            if sourceA >= 0, sourceA < inputChannelCount,
               let base = context.pointee.sourceBase[sourceA] {
                let value = (base + frame * Int(context.pointee.sourceStride[sourceA])).pointee
                sample += value * tap.gainA
                let magnitude = value < 0 ? -value : value
                if magnitude > inputPeak { inputPeak = magnitude }
            }
            let sourceB = Int(tap.sourceB)
            if sourceB >= 0, sourceB < inputChannelCount,
               let base = context.pointee.sourceBase[sourceB] {
                let value = (base + frame * Int(context.pointee.sourceStride[sourceB])).pointee
                sample += value * tap.gainB
                let magnitude = value < 0 ? -value : value
                if magnitude > inputPeak { inputPeak = magnitude }
            }

            let scaled = sample * gain
            let limited = waveClampSample(scaled)
            if limited != scaled { clamped &+= 1 }

            (destination + frame * Int(context.pointee.destinationStride[outputChannel])).pointee = limited

            let magnitude = limited < 0 ? -limited : limited
            if outputChannel == 0, magnitude > meterPeak0 { meterPeak0 = magnitude }
            if outputChannel == 1, magnitude > meterPeak1 { meterPeak1 = magnitude }
        }
    }
    context.pointee.smoother = smoother

    // Short tap buffer: silence the remainder rather than leaving stale audio.
    if renderFrames < outputFrames {
        waveSilence(context, channels: outputChannelCount, from: renderFrames, to: outputFrames)
    }

    WaveRTBlockRaisePeak(block, 0, meterPeak0)
    WaveRTBlockRaisePeak(block, 1, meterPeak1)
    WaveRTBlockRaiseInputPeak(block, inputPeak)
    WaveRTBlockAddCounter(block, WaveRTCounterBuffers, 1)
    WaveRTBlockAddCounter(block, WaveRTCounterFrames, UInt64(renderFrames))
    if clamped > 0 { WaveRTBlockAddCounter(block, WaveRTCounterClampedSamples, clamped) }
    if inputPeak <= SilenceWatchdog.silenceThreshold {
        WaveRTBlockAddCounter(block, WaveRTCounterSilentBuffers, 1)
    }
}

/// Frames in a buffer list, taken from its first non-empty buffer.
@inline(__always)
func waveFrameCount(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int {
    for buffer in buffers {
        let channels = Int(buffer.mNumberChannels)
        guard channels > 0, buffer.mData != nil else { continue }
        return Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
    }
    return 0
}

/// Writes zeros across a frame range of every mapped destination channel.
@inline(__always)
func waveSilence(_ context: UnsafeMutablePointer<RenderContextStorage>,
                 channels: Int,
                 from start: Int,
                 to end: Int) {
    guard end > start else { return }
    for index in 0..<channels {
        guard let base = context.pointee.destinationBase[index] else { continue }
        let stride = Int(context.pointee.destinationStride[index])
        var pointer = base + start * stride
        for _ in start..<end {
            pointer.pointee = 0
            pointer += stride
        }
    }
}

/// Creates, runs and destroys the IO proc for one route.
///
/// Owns the render context's memory and guarantees the only safe teardown
/// order: stop the device, destroy the IO proc, and only then free the storage
/// the callback was reading.
public final class RealtimeRenderer {

    public enum RendererError: Error, CustomStringConvertible {
        case allocationFailed
        case ioProcCreationFailed(CoreAudioError)
        case startFailed(CoreAudioError)

        public var description: String {
            switch self {
            case .allocationFailed:
                return "Could not allocate the render context."
            case .ioProcCreationFailed(let error):
                return error.friendlyExplanation ?? "Could not install the audio callback. \(error)"
            case .startFailed(let error):
                return error.friendlyExplanation ?? "Could not start audio on the routing device. \(error)"
            }
        }
    }

    public let controlBlock: RealtimeControlBlock

    private let deviceID: AudioObjectID
    private let diagnostics: Diagnostics
    private let ioQueue: DispatchQueue
    private var procID: AudioDeviceIOProcID?
    private var context: UnsafeMutablePointer<RenderContextStorage>?
    private var isRunning = false

    public init(deviceID: AudioObjectID,
                plan: RenderPlan,
                controlBlock: RealtimeControlBlock,
                diagnostics: Diagnostics = .shared) throws {
        self.deviceID = deviceID
        self.controlBlock = controlBlock
        self.diagnostics = diagnostics
        // `.userInteractive` is the closest a dispatch queue gets to the
        // priority Core Audio wants; the HAL still promotes the thread it
        // actually calls on.
        self.ioQueue = DispatchQueue(label: "app.wave.render.\(deviceID)", qos: .userInteractive)

        let outputChannels = plan.output.channelCount
        let inputChannels = plan.input.channelCount

        let taps = UnsafeMutablePointer<ChannelTap>.allocate(capacity: max(outputChannels, 1))
        taps.initialize(repeating: .silent, count: max(outputChannels, 1))
        for (index, tap) in plan.channelTaps.enumerated() where index < outputChannels {
            taps[index] = tap
        }

        let sourceBase = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: max(inputChannels, 1))
        sourceBase.initialize(repeating: nil, count: max(inputChannels, 1))
        let sourceStride = UnsafeMutablePointer<Int32>.allocate(capacity: max(inputChannels, 1))
        sourceStride.initialize(repeating: 1, count: max(inputChannels, 1))
        let destinationBase = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: max(outputChannels, 1))
        destinationBase.initialize(repeating: nil, count: max(outputChannels, 1))
        let destinationStride = UnsafeMutablePointer<Int32>.allocate(capacity: max(outputChannels, 1))
        destinationStride.initialize(repeating: 1, count: max(outputChannels, 1))

        let storage = UnsafeMutablePointer<RenderContextStorage>.allocate(capacity: 1)
        let coefficient = GainSmoother.coefficient(sampleRate: plan.output.sampleRate)
        storage.initialize(to: RenderContextStorage(
            block: controlBlock.pointer,
            smoother: GainSmoother(initialGain: 0, coefficient: coefficient),
            hasRendered: false,
            inputChannels: Int32(inputChannels),
            outputChannels: Int32(outputChannels),
            taps: taps,
            sourceBase: sourceBase,
            sourceStride: sourceStride,
            destinationBase: destinationBase,
            destinationStride: destinationStride
        ))
        self.context = storage

        // The block captures only a trivial pointer, so invoking it does not
        // touch ARC.
        let contextPointer = storage
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            waveRender(contextPointer, inInputData, outOutputData)
        }

        var createdProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&createdProcID, deviceID, ioQueue, ioBlock)
        guard status == noErr, let createdProcID else {
            releaseStorage()
            throw RendererError.ioProcCreationFailed(
                CoreAudioError(status, "AudioDeviceCreateIOProcIDWithBlock"))
        }
        self.procID = createdProcID
    }

    deinit { stop() }

    /// Starts the device. This is the call that triggers the macOS system
    /// audio recording prompt the first time round.
    public func start() throws {
        guard !isRunning else { return }
        let status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else {
            throw RendererError.startFailed(CoreAudioError(status, "AudioDeviceStart"))
        }
        isRunning = true
        diagnostics.info("Render", "Started IO on device #\(deviceID)")
    }

    /// Stops the device, removes the callback and frees the render context, in
    /// that order. Idempotent.
    public func stop() {
        if isRunning {
            let status = AudioDeviceStop(deviceID, procID)
            if status != noErr {
                diagnostics.warning("Render", "AudioDeviceStop on #\(deviceID) returned \(status)")
            }
            isRunning = false
        }

        if let procID {
            let status = AudioDeviceDestroyIOProcID(deviceID, procID)
            if status != noErr {
                diagnostics.warning("Render", "AudioDeviceDestroyIOProcID on #\(deviceID) returned \(status)")
            }
            self.procID = nil
        }

        // Only safe once the IO proc is destroyed: until then the callback may
        // still be reading this memory.
        releaseStorage()
    }

    private func releaseStorage() {
        guard let context else { return }
        context.pointee.taps.deallocate()
        context.pointee.sourceBase.deallocate()
        context.pointee.sourceStride.deallocate()
        context.pointee.destinationBase.deallocate()
        context.pointee.destinationStride.deallocate()
        context.deinitialize(count: 1)
        context.deallocate()
        self.context = nil
    }
}
