import Foundation

/// Per-sample gain smoothing.
///
/// Applying a new fader value directly to the multiplier produces a step
/// discontinuity in the waveform, which is audible as a click or a pop. The
/// smoother instead walks the applied gain towards the target with a one-pole
/// filter, so a fader move becomes a short ramp.
///
/// The type is a plain value type holding two floats and performs no
/// allocation, so ``advance()`` is safe to call from the render thread. The
/// coefficient is derived once, off the render thread, by
/// ``GainSmoother/coefficient(timeConstantSeconds:sampleRate:)``.
public struct GainSmoother: Equatable, Sendable {

    /// Time for the ramp to cover ~63% of the distance to a new target.
    /// 15 ms is long enough to remove the click and short enough that a fader
    /// still feels immediate.
    public static let defaultTimeConstantSeconds: Float = 0.015

    /// Below this distance the ramp snaps, which keeps the tail of the
    /// exponential from producing denormal floats in the render loop.
    public static let snapEpsilon: Float = 1e-5

    /// The gain currently being applied.
    public private(set) var current: Float

    /// The gain the smoother is walking towards.
    public private(set) var target: Float

    /// One-pole coefficient in `0...1`.
    public let coefficient: Float

    public init(initialGain: Float = 0, coefficient: Float) {
        let clamped = min(max(initialGain, 0), 1)
        self.current = clamped
        self.target = clamped
        self.coefficient = min(max(coefficient, 0), 1)
    }

    /// Derives the one-pole coefficient for a given ramp time and sample rate.
    ///
    /// `1 - e^(-1 / (tau * fs))` is the standard discretisation. A
    /// non-positive time constant or sample rate degenerates to 1, i.e. an
    /// instant jump, which is the correct behaviour for a smoother that has
    /// been asked not to smooth.
    public static func coefficient(timeConstantSeconds: Float = defaultTimeConstantSeconds,
                                   sampleRate: Double) -> Float {
        guard timeConstantSeconds > 0, sampleRate > 0 else { return 1 }
        let samples = timeConstantSeconds * Float(sampleRate)
        guard samples > 0 else { return 1 }
        return 1 - expf(-1 / samples)
    }

    /// Sets a new destination. Does not move `current`.
    public mutating func setTarget(_ newTarget: Float) {
        target = min(max(newTarget, 0), 1)
    }

    /// Jumps straight to `newValue` with no ramp. Used when a route starts, so
    /// the first buffer is already at the right level instead of fading in.
    public mutating func snap(to newValue: Float) {
        let clamped = min(max(newValue, 0), 1)
        current = clamped
        target = clamped
    }

    /// Advances one sample and returns the gain to apply to it.
    @inline(__always)
    public mutating func advance() -> Float {
        let delta = target - current
        if delta < Self.snapEpsilon && delta > -Self.snapEpsilon {
            current = target
        } else {
            current += delta * coefficient
        }
        return current
    }

    /// `true` once the ramp has arrived.
    public var isSettled: Bool { current == target }
}

/// Combines the fader position and the mute switch into the single linear gain
/// the render thread consumes.
///
/// Mute is deliberately folded into the same value rather than implemented as a
/// separate branch in the render loop: routing it through the smoother means
/// muting and unmuting ramp exactly like a fader move and therefore cannot
/// click.
public enum GainResolver {

    /// - Parameters:
    ///   - position: Fader travel in `0...1`.
    ///   - isMuted: Whether the strip's mute button is engaged.
    ///   - isRouteActive: Whether the route is currently carrying audio. An
    ///     inactive route resolves to silence so a stopped route can never
    ///     leak a partially-faded buffer.
    public static func targetGain(position: Float,
                                  isMuted: Bool,
                                  isRouteActive: Bool = true) -> Float {
        guard isRouteActive, !isMuted else { return 0 }
        return VolumeCurve.gain(forPosition: position)
    }
}

/// Hard clamp applied after gain, purely as a safety net.
///
/// Wave's own gain never exceeds unity, so it cannot itself push a sample past
/// full scale. A source that is already clipping, or a device whose virtual
/// format has less headroom than the tap, still can. Clamping costs two
/// comparisons per sample and guarantees Wave never hands the HAL an
/// out-of-range float.
@inline(__always)
public func waveClampSample(_ sample: Float) -> Float {
    if sample > 1 { return 1 }
    if sample < -1 { return -1 }
    return sample
}
