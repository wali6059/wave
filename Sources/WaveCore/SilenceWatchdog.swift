import Foundation

/// Detects the one failure mode that would otherwise let Wave lie to you.
///
/// macOS enforces the *System Audio Recording* privilege silently. When it is
/// denied, `AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice`
/// and `AudioDeviceStart` all return `noErr` and the IO callback fires on
/// schedule — the tap buffers simply contain digital silence forever. A mixer
/// built naively on top of that looks completely functional: faders move,
/// rows appear, nothing is audible and nothing reports an error.
///
/// The watchdog closes that hole. When Core Audio says an application *is*
/// producing output but every tapped sample has been zero for longer than the
/// grace period, Wave concludes capture is being blocked and says so instead of
/// presenting a working-looking mixer.
///
/// The grace period has to tolerate genuine silence — a paused track, a gap
/// between songs — hence "source claims to be producing output" as the gate,
/// plus a period long enough that ordinary quiet passages do not trip it.
public struct SilenceWatchdog: Equatable, Sendable {

    /// How long an allegedly-active source may deliver pure silence before Wave
    /// stops believing the capture is working.
    public static let defaultGraceInterval: TimeInterval = 4.0

    /// Peak below which a buffer counts as digital silence. Chosen just above
    /// zero rather than at zero so a stream of denormals also counts.
    public static let silenceThreshold: Float = 1e-7

    public enum Verdict: Equatable, Sendable {
        /// Audio is flowing, or the source is legitimately quiet.
        case healthy
        /// The source claims to be playing but nothing is arriving.
        case captureAppearsBlocked
        /// Not enough evidence yet.
        case observing
    }

    public let graceInterval: TimeInterval

    private var silentSince: Date?
    private var sawAudio = false

    public init(graceInterval: TimeInterval = SilenceWatchdog.defaultGraceInterval) {
        self.graceInterval = graceInterval
    }

    /// Feeds one observation.
    ///
    /// - Parameters:
    ///   - peak: Highest absolute sample seen since the last observation.
    ///   - sourceClaimsActive: `kAudioProcessPropertyIsRunningOutput` for the
    ///     tapped application.
    ///   - now: Injected for testability.
    public mutating func observe(peak: Float,
                                 sourceClaimsActive: Bool,
                                 now: Date = Date()) -> Verdict {
        guard sourceClaimsActive else {
            // Nothing is expected, so silence proves nothing. Reset the clock
            // so a long pause does not accumulate towards a false alarm.
            silentSince = nil
            return .healthy
        }

        if peak > Self.silenceThreshold {
            silentSince = nil
            sawAudio = true
            return .healthy
        }

        // Once real audio has been observed through this tap, capture is
        // demonstrably permitted; later silence is the application's own.
        if sawAudio { return .healthy }

        guard let start = silentSince else {
            silentSince = now
            return .observing
        }

        if now.timeIntervalSince(start) >= graceInterval {
            return .captureAppearsBlocked
        }
        return .observing
    }

    /// Forgets everything. Called when a route restarts.
    public mutating func reset() {
        silentSince = nil
        sawAudio = false
    }

    public var hasEverSeenAudio: Bool { sawAudio }
}
