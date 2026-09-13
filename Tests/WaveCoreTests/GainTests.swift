import XCTest
@testable import WaveCore

final class VolumeCurveTests: XCTestCase {

    /// The two anchors that make the curve safe: full travel is exactly unity
    /// (so Wave can never boost and therefore can never introduce clipping),
    /// and zero travel is exactly silence (not a very small number).
    func testAnchorsAreExact() {
        XCTAssertEqual(VolumeCurve.gain(forPosition: 1), 1.0)
        XCTAssertEqual(VolumeCurve.gain(forPosition: 0), 0.0)
    }

    func testNeverExceedsUnity() {
        for step in 0...200 {
            let position = Float(step) / 100 // deliberately walks past 1.0
            XCTAssertLessThanOrEqual(VolumeCurve.gain(forPosition: position), 1.0,
                                     "gain must never boost at position \(position)")
            XCTAssertGreaterThanOrEqual(VolumeCurve.gain(forPosition: position), 0.0)
        }
    }

    func testClampsNegativePositions() {
        XCTAssertEqual(VolumeCurve.gain(forPosition: -0.5), 0)
    }

    func testIsMonotonic() {
        var previous = VolumeCurve.gain(forPosition: 0)
        for step in 1...100 {
            let gain = VolumeCurve.gain(forPosition: Float(step) / 100)
            XCTAssertGreaterThanOrEqual(gain, previous, "curve dipped at \(step)%")
            previous = gain
        }
    }

    func testSquareLawValues() {
        XCTAssertEqual(VolumeCurve.gain(forPosition: 0.5), 0.25, accuracy: 1e-6)
        XCTAssertEqual(VolumeCurve.gain(forPosition: 0.1), 0.01, accuracy: 1e-6)
    }

    func testRoundTripsThroughPosition() {
        for step in 0...100 {
            let position = Float(step) / 100
            let gain = VolumeCurve.gain(forPosition: position)
            XCTAssertEqual(VolumeCurve.position(forGain: gain), position, accuracy: 1e-4)
        }
    }

    func testDecibels() {
        XCTAssertEqual(VolumeCurve.decibels(forGain: 1), 0, accuracy: 1e-5)
        XCTAssertEqual(VolumeCurve.decibels(forGain: 0.5), -6.0206, accuracy: 1e-3)
        XCTAssertEqual(VolumeCurve.decibels(forGain: 0), -.infinity)
    }

    func testPercentRounding() {
        XCTAssertEqual(VolumeCurve.percent(forPosition: 0.725), 73)
        XCTAssertEqual(VolumeCurve.percent(forPosition: 0), 0)
        XCTAssertEqual(VolumeCurve.percent(forPosition: 1), 100)
    }
}

final class GainSmootherTests: XCTestCase {

    private func makeSmoother(sampleRate: Double = 48_000,
                              timeConstant: Float = GainSmoother.defaultTimeConstantSeconds) -> GainSmoother {
        GainSmoother(initialGain: 0,
                     coefficient: GainSmoother.coefficient(timeConstantSeconds: timeConstant,
                                                           sampleRate: sampleRate))
    }

    func testCoefficientIsInRange() {
        let coefficient = GainSmoother.coefficient(sampleRate: 48_000)
        XCTAssertGreaterThan(coefficient, 0)
        XCTAssertLessThan(coefficient, 1)
    }

    func testDegenerateInputsJumpImmediately() {
        XCTAssertEqual(GainSmoother.coefficient(timeConstantSeconds: 0, sampleRate: 48_000), 1)
        XCTAssertEqual(GainSmoother.coefficient(timeConstantSeconds: 0.015, sampleRate: 0), 1)
    }

    /// The whole reason the smoother exists: a fader move must not produce a
    /// step in the waveform.
    func testRampIsGradualNotAStep() {
        var smoother = makeSmoother()
        smoother.snap(to: 1.0)
        smoother.setTarget(0.0)

        let first = smoother.advance()
        XCTAssertLessThan(first, 1.0, "gain should have started falling")
        XCTAssertGreaterThan(first, 0.9, "one sample must not cover the whole distance")
    }

    /// A one-pole ramp covers 1 - e^-n of the distance in n time constants, so
    /// five gets to 99.3% and ten to 99.995%. Both are asserted because the
    /// first is what makes a fader feel immediate and the second is what stops
    /// a level sitting fractionally below its target forever.
    func testRampConvergesAtTheExpectedRate() {
        let sampleRate = 48_000.0
        let timeConstant: Float = 0.015
        let samplesPerTimeConstant = Int(Double(timeConstant) * sampleRate)

        var smoother = makeSmoother(sampleRate: sampleRate, timeConstant: timeConstant)
        smoother.setTarget(1.0)
        for _ in 0..<(samplesPerTimeConstant * 5) { _ = smoother.advance() }
        XCTAssertEqual(smoother.current, 1 - expf(-5), accuracy: 1e-3)

        for _ in 0..<(samplesPerTimeConstant * 5) { _ = smoother.advance() }
        XCTAssertEqual(smoother.current, 1.0, accuracy: 1e-3)
    }

    /// Regression: the ramp used to stall short of its target forever.
    ///
    /// The per-sample step is `delta * coefficient`. Both shrink as the ramp
    /// converges, and once the product drops below half a ULP the addition
    /// rounds to no change. At 48 kHz that happened while `delta` was still
    /// ~2.1e-5 — above `snapEpsilon`, so the snap never fired and the gain sat
    /// just under unity indefinitely.
    func testRampAlwaysReachesItsTargetExactly() {
        var smoother = makeSmoother()
        smoother.setTarget(1.0)
        for _ in 0..<100_000 { _ = smoother.advance() }
        XCTAssertTrue(smoother.isSettled, "the ramp stalled instead of settling")
        XCTAssertEqual(smoother.current, 1.0)
    }

    /// The hazard is worse the smaller the coefficient, because the step runs
    /// out of float resolution while `delta` is still comparatively large.
    ///
    /// Sweeping the coefficient directly rather than (time constant, sample
    /// rate) pairs is both the honest variable — the coefficient is what
    /// governs the stall — and far cheaper, since a slow ramp expressed as a
    /// long time constant at a high sample rate needs tens of millions of
    /// samples just to converge.
    func testRampSettlesForEveryPlausibleCoefficient() {
        let coefficients: [Float] = [
            1.0,        // no smoothing
            0.5,
            0.1,
            0.01,
            GainSmoother.coefficient(sampleRate: 48_000),   // Wave's default
            GainSmoother.coefficient(sampleRate: 192_000),
            1e-4,
            1e-5,       // absurdly slow; still must terminate
        ]

        for coefficient in coefficients {
            for target: Float in [0.0, 0.25, 1.0] {
                let start: Float = target == 0 ? 1.0 : 0.0
                var smoother = GainSmoother(initialGain: start, coefficient: coefficient)
                smoother.setTarget(target)

                var iterations = 0
                let budget = 5_000_000
                while !smoother.isSettled && iterations < budget {
                    _ = smoother.advance()
                    iterations += 1
                }

                XCTAssertTrue(smoother.isSettled,
                              "coefficient \(coefficient) target \(target) never settled "
                              + "(stuck at \(smoother.current) after \(iterations) samples)")
                XCTAssertEqual(smoother.current, target)
            }
        }
    }

    /// The ramp must approach its target from one side only. An overshoot past
    /// 1.0 would be the one way the gain stage could clip on its own.
    func testRampIsMonotonicAndNeverOvershoots() {
        var smoother = makeSmoother()
        smoother.setTarget(1.0)
        var previous = smoother.current
        while !smoother.isSettled {
            let value = smoother.advance()
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThanOrEqual(value, 1.0)
            previous = value
        }
    }

    func testTargetIsClamped() {
        var smoother = makeSmoother()
        smoother.setTarget(5)
        XCTAssertEqual(smoother.target, 1)
        smoother.setTarget(-5)
        XCTAssertEqual(smoother.target, 0)
    }

    func testSnapAppliesImmediately() {
        var smoother = makeSmoother()
        smoother.snap(to: 0.7)
        XCTAssertEqual(smoother.current, 0.7)
        XCTAssertEqual(smoother.advance(), 0.7)
    }

    /// A ramp must never overshoot; an overshoot past 1.0 would clip.
    func testNeverOvershoots() {
        var smoother = makeSmoother()
        smoother.setTarget(1.0)
        for _ in 0..<5_000 {
            XCTAssertLessThanOrEqual(smoother.advance(), 1.0)
        }
    }
}

final class GainResolverTests: XCTestCase {

    func testMuteResolvesToSilence() {
        XCTAssertEqual(GainResolver.targetGain(position: 1.0, isMuted: true), 0)
        XCTAssertEqual(GainResolver.targetGain(position: 0.5, isMuted: true), 0)
    }

    func testInactiveRouteResolvesToSilence() {
        XCTAssertEqual(GainResolver.targetGain(position: 1.0, isMuted: false, isRouteActive: false), 0)
    }

    func testUnmutedUsesTheCurve() {
        XCTAssertEqual(GainResolver.targetGain(position: 0.5, isMuted: false), 0.25, accuracy: 1e-6)
    }
}

final class ClampTests: XCTestCase {

    func testClampBounds() {
        XCTAssertEqual(waveClampSample(2.0), 1.0)
        XCTAssertEqual(waveClampSample(-2.0), -1.0)
        XCTAssertEqual(waveClampSample(0.5), 0.5)
        XCTAssertEqual(waveClampSample(0), 0)
    }

    /// Wave's own gain stage cannot produce an out-of-range sample from an
    /// in-range one, so the clamp only ever fires on already-hot sources.
    func testGainStageCannotClipAnInRangeSource() {
        for step in 0...100 {
            let gain = VolumeCurve.gain(forPosition: Float(step) / 100)
            for sample in stride(from: Float(-1), through: 1, by: 0.05) {
                let processed = sample * gain
                XCTAssertEqual(waveClampSample(processed), processed, accuracy: 1e-6)
            }
        }
    }
}
