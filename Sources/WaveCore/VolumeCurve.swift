import Foundation

/// Maps the 0...1 slider position the user manipulates onto a linear amplitude
/// multiplier applied to sample data.
///
/// A linear slider driving a linear gain feels wrong: almost all of the useful
/// range bunches up at the bottom of the travel. `Wave` uses a square-law
/// taper, which is the same family of curve Apple's own volume sliders use and
/// which puts sensible values at the places people actually park a fader:
///
/// | position | gain   | dB     |
/// |----------|--------|--------|
/// | 1.00     | 1.0000 |   0.0  |
/// | 0.71     | 0.5041 |  -5.9  |
/// | 0.50     | 0.2500 | -12.0  |
/// | 0.30     | 0.0900 | -20.9  |
/// | 0.10     | 0.0100 | -40.0  |
/// | 0.00     | 0.0000 |  -inf  |
///
/// Two properties matter and are asserted by the test suite:
///
/// * `gain(1) == 1` exactly. 100% is unity, never a boost. Wave can only ever
///   attenuate what an application produces, which is what makes it impossible
///   for the mixer itself to introduce clipping.
/// * `gain(0) == 0` exactly, so a fader at the bottom is true digital silence
///   rather than a very small number.
public enum VolumeCurve {

    /// Exponent of the taper. 2.0 is a square law.
    public static let exponent: Float = 2.0

    /// Amplitude multiplier for a normalised slider position.
    /// - Parameter position: Slider travel, clamped into `0...1`.
    public static func gain(forPosition position: Float) -> Float {
        let clamped = min(max(position, 0), 1)
        if clamped <= 0 { return 0 }
        if clamped >= 1 { return 1 }
        return powf(clamped, exponent)
    }

    /// Inverse of ``gain(forPosition:)``. Used when a saved rule stores a gain
    /// and the UI needs to place the fader.
    public static func position(forGain gain: Float) -> Float {
        let clamped = min(max(gain, 0), 1)
        if clamped <= 0 { return 0 }
        if clamped >= 1 { return 1 }
        return powf(clamped, 1 / exponent)
    }

    /// Convenience for display and diagnostics. Returns `-.infinity` at silence.
    public static func decibels(forGain gain: Float) -> Float {
        guard gain > 0 else { return -.infinity }
        return 20 * log10f(gain)
    }

    /// The integer percentage Wave shows next to a fader.
    public static func percent(forPosition position: Float) -> Int {
        Int((min(max(position, 0), 1) * 100).rounded())
    }
}
