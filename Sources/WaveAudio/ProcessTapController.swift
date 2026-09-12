import Foundation
import CoreAudio
import AudioToolbox
import WaveCore

/// Owns the Core Audio objects that make one application's audio available to
/// Wave and keep it away from the speakers it would otherwise reach.
///
/// Two objects are created together because neither is useful alone:
///
/// 1. **A process tap** (`AudioHardwareCreateProcessTap`) over every process
///    object belonging to the application. `muteBehavior = .mutedWhenTapped` is
///    what satisfies "do not let the original stream also reach the default
///    device": while the tap exists, macOS stops routing that process to its
///    normal destination, and the moment the tap is destroyed — including if
///    Wave crashes — normal playback resumes on its own. That property is why
///    Wave has no "restore audio" repair step to get wrong.
///
/// 2. **A private aggregate device** whose sub-device is the destination the
///    user chose and whose tap list is the tap above. This is the supported way
///    to read a tap's output: the aggregate presents the tapped audio as input
///    streams and the destination hardware as output streams, so a single
///    `AudioDeviceIOProc` receives the captured audio and hands back the
///    processed audio in one pass, on one clock, with no ring buffer and no
///    resampling of Wave's own.
///
/// One aggregate per route rather than one per device is deliberate. Adding or
/// removing an application then rebuilds only that application's plumbing
/// instead of glitching every app sharing the destination.
public final class ProcessTapController {

    public struct Configuration {
        public var processObjectIDs: [AudioObjectID]
        public var destinationDeviceUID: String
        /// Used only for naming and diagnostics.
        public var label: String
        /// When true, the tapped application is muted on its normal output path
        /// for as long as the tap lives. Always true while Wave is routing;
        /// exposed so the spike can demonstrate both behaviours.
        public var muteOriginalOutput: Bool

        public init(processObjectIDs: [AudioObjectID],
                    destinationDeviceUID: String,
                    label: String,
                    muteOriginalOutput: Bool = true) {
            self.processObjectIDs = processObjectIDs
            self.destinationDeviceUID = destinationDeviceUID
            self.label = label
            self.muteOriginalOutput = muteOriginalOutput
        }
    }

    public enum PreparationError: Error, CustomStringConvertible {
        case noProcesses
        case tapCreationFailed(CoreAudioError)
        case aggregateCreationFailed(CoreAudioError)
        case tapFormatUnavailable(CoreAudioError)
        case aggregateStreamsUnavailable(String)
        case incompatibleFormats(FormatIncompatibility)

        public var description: String {
            switch self {
            case .noProcesses:
                return "That application is not registered with Core Audio as an audio process."
            case .tapCreationFailed(let error):
                return error.friendlyExplanation ?? "Could not create the process tap. \(error)"
            case .aggregateCreationFailed(let error):
                return error.friendlyExplanation ?? "Could not create the routing device. \(error)"
            case .tapFormatUnavailable(let error):
                return "Could not read the tap's audio format. \(error)"
            case .aggregateStreamsUnavailable(let detail):
                return detail
            case .incompatibleFormats(let reason):
                return reason.description
            }
        }
    }

    /// Everything a prepared route needs to start rendering.
    public struct Prepared {
        public let tapID: AudioObjectID
        public let tapUUID: UUID
        public let aggregateDeviceID: AudioObjectID
        public let plan: RenderPlan
        /// Frames the aggregate will ask for per callback, used only to size
        /// diagnostics.
        public let bufferFrameSize: UInt32
    }

    private let diagnostics: Diagnostics
    private var tapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var tapUUID: UUID?

    public init(diagnostics: Diagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    deinit { tearDown() }

    // MARK: - Preparation

    public func prepare(_ configuration: Configuration) throws -> Prepared {
        guard !configuration.processObjectIDs.isEmpty else { throw PreparationError.noProcesses }

        // A stereo mixdown over the whole process group means one tap covers an
        // application and all of its helpers, and the row in the mixer maps to
        // exactly one thing to start and stop.
        let description = CATapDescription(stereoMixdownOfProcesses: configuration.processObjectIDs)
        let uuid = UUID()
        description.uuid = uuid
        description.name = "\(AudioDeviceRegistry.aggregateNamePrefix) tap - \(configuration.label)"
        description.muteBehavior = configuration.muteOriginalOutput ? .mutedWhenTapped : .unmuted
        // Private keeps the tap out of every other app's device list.
        description.isPrivate = true

        var createdTapID: AudioObjectID = .unknown
        var status = AudioHardwareCreateProcessTap(description, &createdTapID)

        if status != noErr && description.isPrivate {
            // Some configurations refuse a private tap. A visible tap is worse
            // for tidiness but identical for correctness, so retry rather than
            // fail the route, and record that it happened.
            diagnostics.warning("Tap",
                                "Private tap for \(configuration.label) failed (\(status)); retrying as a visible tap")
            description.isPrivate = false
            status = AudioHardwareCreateProcessTap(description, &createdTapID)
        }

        guard status == noErr, createdTapID.isValid else {
            throw PreparationError.tapCreationFailed(CoreAudioError(status, "AudioHardwareCreateProcessTap"))
        }
        tapID = createdTapID
        tapUUID = uuid
        diagnostics.info("Tap", "Created tap #\(createdTapID) for \(configuration.label) "
                         + "over \(configuration.processObjectIDs.count) process object(s)")

        do {
            let aggregate = try createAggregate(tapUUID: uuid, configuration: configuration)
            aggregateDeviceID = aggregate

            let plan = try makeRenderPlan(aggregateDeviceID: aggregate)
            let frames: UInt32 = (try? aggregate.read(kAudioDevicePropertyBufferFrameSize,
                                                      defaultValue: UInt32(0))) ?? 0

            return Prepared(tapID: createdTapID,
                            tapUUID: uuid,
                            aggregateDeviceID: aggregate,
                            plan: plan,
                            bufferFrameSize: frames)
        } catch {
            // Never leave a tap behind on a partial failure: a stranded tap
            // with `mutedWhenTapped` would keep that application silent.
            tearDown()
            throw error
        }
    }

    private func createAggregate(tapUUID: UUID, configuration: Configuration) throws -> AudioObjectID {
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(AudioDeviceRegistry.aggregateNamePrefix) - \(configuration.label)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            // The destination hardware is the clock master, so the tap is
            // rate-converted onto it by the HAL and Wave never has to resample.
            kAudioAggregateDeviceMainSubDeviceKey: configuration.destinationDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: configuration.destinationDeviceUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]

        var deviceID: AudioObjectID = .unknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        guard status == noErr, deviceID.isValid else {
            throw PreparationError.aggregateCreationFailed(
                CoreAudioError(status, "AudioHardwareCreateAggregateDevice"))
        }
        diagnostics.info("Tap", "Created aggregate #\(deviceID) -> \(configuration.destinationDeviceUID)")
        return deviceID
    }

    /// Reads the formats the IO callback will actually see and decides how the
    /// tapped channels map onto the destination's.
    ///
    /// The formats are read from the *aggregate*, not from the tap and the
    /// device separately, because the aggregate is what the callback talks to:
    /// its input side is the tap after any conversion the HAL performed, and
    /// its output side is the destination. Reading them from the same object is
    /// what guarantees the two agree on sample rate.
    private func makeRenderPlan(aggregateDeviceID: AudioObjectID) throws -> RenderPlan {
        let inputFormat = try Self.aggregateFormat(aggregateDeviceID, scope: kAudioObjectPropertyScopeInput)
        let outputFormat = try Self.aggregateFormat(aggregateDeviceID, scope: kAudioObjectPropertyScopeOutput)

        switch RenderPlanBuilder.makePlan(input: inputFormat, output: outputFormat) {
        case .success(let plan):
            diagnostics.info("Tap",
                             "Render plan: \(inputFormat.channelCount)ch in -> "
                             + "\(outputFormat.channelCount)ch out @ \(Int(outputFormat.sampleRate)) Hz")
            return plan
        case .failure(let reason):
            throw PreparationError.incompatibleFormats(reason)
        }
    }

    /// Collapses every stream on one scope into a single ``AudioFormatSpec``.
    static func aggregateFormat(_ deviceID: AudioObjectID,
                                scope: AudioObjectPropertyScope) throws -> AudioFormatSpec {
        let streams: [AudioObjectID]
        do {
            streams = try deviceID.readArray(kAudioObjectPropertyStreams,
                                             scope: scope,
                                             filler: AudioObjectID.unknown)
        } catch let error as CoreAudioError {
            throw PreparationError.aggregateStreamsUnavailable(
                "Could not read the routing device's streams. \(error)")
        }

        let scopeName = scope == kAudioObjectPropertyScopeInput ? "input" : "output"
        guard !streams.isEmpty else {
            throw PreparationError.aggregateStreamsUnavailable(
                "The routing device exposed no \(scopeName) streams.")
        }

        var totalChannels = 0
        var sampleRate: Double = 0
        var isFloat32 = true
        var isInterleaved = false

        for stream in streams where stream.isValid {
            guard let asbd: AudioStreamBasicDescription = try? stream.read(kAudioStreamPropertyVirtualFormat,
                                                                           defaultValue: AudioStreamBasicDescription()) else {
                continue
            }
            totalChannels += Int(asbd.mChannelsPerFrame)
            if sampleRate == 0 { sampleRate = asbd.mSampleRate }
            let flags = asbd.mFormatFlags
            let float = asbd.mFormatID == kAudioFormatLinearPCM
                && (flags & kAudioFormatFlagIsFloat) != 0
                && asbd.mBitsPerChannel == 32
            isFloat32 = isFloat32 && float
            // Core Audio marks non-interleaved explicitly; anything else with
            // more than one channel per frame is interleaved.
            if (flags & kAudioFormatFlagIsNonInterleaved) == 0 && asbd.mChannelsPerFrame > 1 {
                isInterleaved = true
            }
        }

        guard totalChannels > 0, sampleRate > 0 else {
            throw PreparationError.aggregateStreamsUnavailable(
                "The routing device reported an empty \(scopeName) format.")
        }

        return AudioFormatSpec(sampleRate: sampleRate,
                               channelCount: totalChannels,
                               isInterleaved: isInterleaved,
                               isFloat32: isFloat32)
    }

    // MARK: - Teardown

    /// Destroys the aggregate first, then the tap.
    ///
    /// Order matters: destroying the tap while an aggregate still references it
    /// leaves the aggregate pointing at nothing. Both are idempotent so a
    /// double teardown (explicit stop followed by `deinit`) is harmless.
    public func tearDown() {
        if aggregateDeviceID.isValid {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if status != noErr {
                diagnostics.warning("Tap", "Destroying aggregate #\(aggregateDeviceID) returned \(status)")
            }
            aggregateDeviceID = .unknown
        }

        if tapID.isValid {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr {
                diagnostics.warning("Tap", "Destroying tap #\(tapID) returned \(status)")
            }
            tapID = .unknown
        }
        tapUUID = nil
    }
}
