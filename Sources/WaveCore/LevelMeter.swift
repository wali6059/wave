import Foundation

/// Ballistics for the level meters.
///
/// The render thread only ever publishes a raw peak. All of the smoothing that
/// makes a meter readable — the fast attack, the slow release, the peak-hold
/// that lingers so a transient is visible at 30 fps — happens here, on the UI
/// side, where it is cheap and testable and cannot affect audio.
public struct MeterBallistics: Equatable, Sendable {

    /// How far the displayed level falls per second once the signal drops.
    /// 20 dB/s is the broadcast convention and reads as "musical" rather than
    /// twitchy.
    public static let defaultReleaseDBPerSecond: Float = 20

    /// How long the peak marker sits at its high-water mark before falling.
    public static let defaultPeakHoldSeconds: TimeInterval = 1.2

    /// Bottom of the meter scale.
    public static let floorDB: Float = -60

    public var releaseDBPerSecond: Float
    public var peakHoldSeconds: TimeInterval

    /// Currently displayed level, normalised to `0...1` across the dB scale.
    public private(set) var displayLevel: Float = 0
    /// Position of the peak-hold marker, same normalisation.
    public private(set) var peakLevel: Float = 0

    private var peakSetAt: Date?

    public init(releaseDBPerSecond: Float = MeterBallistics.defaultReleaseDBPerSecond,
                peakHoldSeconds: TimeInterval = MeterBallistics.defaultPeakHoldSeconds) {
        self.releaseDBPerSecond = releaseDBPerSecond
        self.peakHoldSeconds = peakHoldSeconds
    }

    /// Converts a linear amplitude to the meter's normalised scale.
    public static func normalised(amplitude: Float) -> Float {
        guard amplitude > 0 else { return 0 }
        let db = 20 * log10f(min(amplitude, 1))
        guard db > floorDB else { return 0 }
        return (db - floorDB) / -floorDB
    }

    /// Advances the meter.
    ///
    /// - Parameters:
    ///   - amplitude: Peak amplitude drained from the render thread.
    ///   - elapsed: Seconds since the previous update.
    ///   - now: Injected for testability.
    public mutating func update(amplitude: Float, elapsed: TimeInterval, now: Date = Date()) {
        let incoming = Self.normalised(amplitude: amplitude)

        if incoming >= displayLevel {
            // Instant attack: a transient that is not shown immediately is not
            // a level meter, it is a decoration.
            displayLevel = incoming
        } else {
            let fallInDB = releaseDBPerSecond * Float(max(elapsed, 0))
            let fallNormalised = fallInDB / -Self.floorDB
            displayLevel = max(incoming, displayLevel - fallNormalised)
        }
        displayLevel = min(max(displayLevel, 0), 1)

        if displayLevel >= peakLevel {
            peakLevel = displayLevel
            peakSetAt = now
        } else if let setAt = peakSetAt, now.timeIntervalSince(setAt) > peakHoldSeconds {
            let fallNormalised = (releaseDBPerSecond * Float(max(elapsed, 0))) / -Self.floorDB
            peakLevel = max(displayLevel, peakLevel - fallNormalised)
        }
        peakLevel = min(max(peakLevel, 0), 1)
    }

    /// Drops the meter to the floor at once. Used when a route stops, so a
    /// stale bar is never left lit.
    public mutating func reset() {
        displayLevel = 0
        peakLevel = 0
        peakSetAt = nil
    }
}

/// Left/right pair of meters for one application.
public struct StereoMeter: Equatable, Sendable {
    public var left = MeterBallistics()
    public var right = MeterBallistics()

    public init() {}

    public mutating func update(leftAmplitude: Float,
                                rightAmplitude: Float,
                                elapsed: TimeInterval,
                                now: Date = Date()) {
        left.update(amplitude: leftAmplitude, elapsed: elapsed, now: now)
        right.update(amplitude: rightAmplitude, elapsed: elapsed, now: now)
    }

    public mutating func reset() {
        left.reset()
        right.reset()
    }

    /// True when neither channel is showing anything, used to decide whether a
    /// row belongs in the "active" section.
    public var isSilent: Bool { left.displayLevel <= 0 && right.displayLevel <= 0 }
}
