import Foundation

/// A Core Audio stream format reduced to the facts the render loop needs.
///
/// Deliberately a plain value type rather than `AudioStreamBasicDescription`
/// so that format negotiation can be reasoned about and unit-tested without
/// linking Core Audio.
public struct AudioFormatSpec: Equatable, Sendable {
    public var sampleRate: Double
    public var channelCount: Int
    public var isInterleaved: Bool
    /// Wave only renders 32-bit float. Anything else is rejected rather than
    /// reinterpreted, because reinterpreting the wrong format is the difference
    /// between quiet audio and full-scale noise in somebody's headphones.
    public var isFloat32: Bool

    public init(sampleRate: Double, channelCount: Int, isInterleaved: Bool, isFloat32: Bool) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.isInterleaved = isInterleaved
        self.isFloat32 = isFloat32
    }
}

/// Why a tap format and a device format could not be connected.
public enum FormatIncompatibility: Error, Equatable, Sendable, CustomStringConvertible {
    case inputNotFloat32
    case outputNotFloat32
    case sampleRateMismatch(input: Double, output: Double)
    case emptyInput
    case emptyOutput
    case channelCountUnsupported(input: Int, output: Int)

    public var description: String {
        switch self {
        case .inputNotFloat32:
            return "The process tap did not report a 32-bit float format."
        case .outputNotFloat32:
            return "The output device did not report a 32-bit float format."
        case .sampleRateMismatch(let input, let output):
            return "Tap runs at \(Int(input)) Hz but the output device runs at \(Int(output)) Hz."
        case .emptyInput:
            return "The process tap reported zero channels."
        case .emptyOutput:
            return "The output device reported zero channels."
        case .channelCountUnsupported(let input, let output):
            return "Cannot map \(input) tapped channels onto \(output) output channels."
        }
    }
}

/// How one output channel is built from the tapped channels.
///
/// Two sources with independent weights is enough to express every mapping
/// Wave performs (pass-through, mono fan-out, stereo fold-down) while staying
/// a fixed-size POD that can live inline in the render context.
public struct ChannelTap: Equatable, Sendable {
    /// Index into the tapped channels, or `-1` for "contributes nothing".
    public var sourceA: Int32
    public var sourceB: Int32
    public var gainA: Float
    public var gainB: Float

    public static let silent = ChannelTap(sourceA: -1, sourceB: -1, gainA: 0, gainB: 0)

    public init(sourceA: Int32, sourceB: Int32, gainA: Float, gainB: Float) {
        self.sourceA = sourceA
        self.sourceB = sourceB
        self.gainA = gainA
        self.gainB = gainB
    }

    public static func copy(_ source: Int) -> ChannelTap {
        ChannelTap(sourceA: Int32(source), sourceB: -1, gainA: 1, gainB: 0)
    }

    public static func mix(_ a: Int, _ b: Int, weight: Float = 0.5) -> ChannelTap {
        ChannelTap(sourceA: Int32(a), sourceB: Int32(b), gainA: weight, gainB: weight)
    }

    public var isSilent: Bool { sourceA < 0 && sourceB < 0 }
}

/// The complete, pre-computed description of one render pass.
///
/// Everything the IO callback needs is resolved here, on the control thread,
/// so the callback itself contains no decisions that could allocate, branch
/// unpredictably or consult shared mutable state.
public struct RenderPlan: Equatable, Sendable {
    public var input: AudioFormatSpec
    public var output: AudioFormatSpec
    /// One entry per output channel, in output channel order.
    public var channelTaps: [ChannelTap]

    public init(input: AudioFormatSpec, output: AudioFormatSpec, channelTaps: [ChannelTap]) {
        self.input = input
        self.output = output
        self.channelTaps = channelTaps
    }
}

/// Decides whether a tap can feed a device, and how its channels line up.
public enum RenderPlanBuilder {

    /// Largest channel count the render context can describe. Mirrors
    /// `WAVE_MAX_CHANNELS` in `WaveRTSupport.h`.
    public static let maxChannels = 64

    public static func makePlan(input: AudioFormatSpec,
                                output: AudioFormatSpec) -> Result<RenderPlan, FormatIncompatibility> {
        guard input.isFloat32 else { return .failure(.inputNotFloat32) }
        guard output.isFloat32 else { return .failure(.outputNotFloat32) }
        guard input.channelCount > 0 else { return .failure(.emptyInput) }
        guard output.channelCount > 0 else { return .failure(.emptyOutput) }
        guard input.channelCount <= maxChannels, output.channelCount <= maxChannels else {
            return .failure(.channelCountUnsupported(input: input.channelCount,
                                                     output: output.channelCount))
        }
        // Both sides of the render pass are pulled from a single aggregate
        // device, so the HAL has already rate-converted the tap onto the
        // aggregate's clock. A mismatch here means an assumption has broken and
        // resampling in the callback would be the wrong fix.
        guard input.sampleRate == output.sampleRate else {
            return .failure(.sampleRateMismatch(input: input.sampleRate, output: output.sampleRate))
        }

        let taps = channelTaps(inputChannels: input.channelCount,
                               outputChannels: output.channelCount)
        return .success(RenderPlan(input: input, output: output, channelTaps: taps))
    }

    /// The channel mapping policy, separated out so it can be tested directly.
    public static func channelTaps(inputChannels: Int, outputChannels: Int) -> [ChannelTap] {
        precondition(inputChannels > 0 && outputChannels > 0)
        var taps = [ChannelTap](repeating: .silent, count: outputChannels)

        if inputChannels == 1 {
            // Mono source: fan out to the front pair so it is not stuck in one
            // ear, and leave surround channels alone.
            for channel in 0..<min(2, outputChannels) {
                taps[channel] = .copy(0)
            }
        } else if outputChannels == 1 {
            // Fold the first two channels down. Equal-weight rather than
            // -3 dB compensated: Wave never boosts, and an equal-weight
            // fold-down cannot exceed the loudest contributing channel.
            taps[0] = .mix(0, 1)
        } else {
            // Straight pass-through for the channels both sides have; anything
            // the source does not provide stays silent rather than being
            // synthesised.
            for channel in 0..<min(inputChannels, outputChannels) {
                taps[channel] = .copy(channel)
            }
        }
        return taps
    }
}
