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

    func testReachesTargetWithinAboutFiveTimeConstants() {
        let sampleRate = 48_000.0
        let timeConstant: Float = 0.015
        var smoother = makeSmoother(sampleRate: sampleRate, timeConstant: timeConstant)
        smoother.setTarget(1.0)

        let samples = Int(Double(timeConstant) * sampleRate * 5)
        for _ in 0..<samples { _ = smoother.advance() }

        XCTAssertEqual(smoother.current, 1.0, accuracy: 1e-3)
    }

    func testSnapsWithinEpsilonToAvoidDenormals() {
        var smoother = makeSmoother()
        smoother.setTarget(1.0)
        for _ in 0..<100_000 { _ = smoother.advance() }
        XCTAssertTrue(smoother.isSettled)
        XCTAssertEqual(smoother.current, 1.0)
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
