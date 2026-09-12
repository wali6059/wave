import XCTest
@testable import WaveCore

final class SilenceWatchdogTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// The whole reason this type exists: with capture denied, every Core Audio
    /// call returns success and the buffers are silent forever. Without this,
    /// Wave would show a mixer that looks like it works.
    func testSilentTapFromAnActiveSourceIsEventuallyReportedAsBlocked() {
        var watchdog = SilenceWatchdog(graceInterval: 4)
        XCTAssertEqual(watchdog.observe(peak: 0, sourceClaimsActive: true, now: start), .observing)
        XCTAssertEqual(watchdog.observe(peak: 0, sourceClaimsActive: true,
                                        now: start.addingTimeInterval(2)), .observing)
        XCTAssertEqual(watchdog.observe(peak: 0, sourceClaimsActive: true,
                                        now: start.addingTimeInterval(4.1)), .captureAppearsBlocked)
    }

    /// A paused track is not a permission failure.
    func testSilenceFromAnIdleSourceProvesNothing() {
        var watchdog = SilenceWatchdog(graceInterval: 1)
        XCTAssertEqual(watchdog.observe(peak: 0, sourceClaimsActive: false, now: start), .healthy)
        XCTAssertEqual(watchdog.observe(peak: 0, sourceClaimsActive: false,
                                        now: start.addingTimeInterval(600)), .healthy)
    }

    func testAnyAudioClearsTheAlarm() {
        var watchdog = SilenceWatchdog(graceInterval: 1)
        _ = watchdog.observe(peak: 0, sourceClaimsActive: true, now: start)
        XCTAssertEqual(watchdog.observe(peak: 0.3, sourceClaimsActive: true,
                                        now: start.addingTimeInterval(0.5)), .healthy)
        XCTAssertTrue(watchdog.hasEverSeenAudio)
    }

    /// Once capture has demonstrably worked, later silence is the application's
    /// own — a quiet passage must never be reported as a permission problem.
    func testOnceProvenTheWatchdogStopsSuspectingPermission() {
        var watchdog = SilenceWatchdog(graceInterval: 1)
        _ = watchdog.observe(peak: 0.5, sourceClaimsActive: true, now: start)
        XCTAssertEqual(watchdog.observe(peak: 0, sourceClaimsActive: true,
                                        now: start.addingTimeInterval(3600)), .healthy)
    }

    func testAPauseResetsTheClock() {
        var watchdog = SilenceWatchdog(graceInterval: 4)
        _ = watchdog.observe(peak: 0, sourceClaimsActive: true, now: start)
        // The source stops claiming to be active, which resets the timer.
        _ = watchdog.observe(peak: 0, sourceClaimsActive: false, now: start.addingTimeInterval(3))
        XCTAssertEqual(watchdog.observe(peak: 0, sourceClaimsActive: true,
                                        now: start.addingTimeInterval(5)), .observing)
    }

    func testDenormalsCountAsSilence() {
        var watchdog = SilenceWatchdog(graceInterval: 1)
        _ = watchdog.observe(peak: 1e-9, sourceClaimsActive: true, now: start)
        XCTAssertEqual(watchdog.observe(peak: 1e-9, sourceClaimsActive: true,
                                        now: start.addingTimeInterval(2)), .captureAppearsBlocked)
    }

    func testResetForgetsEverything() {
        var watchdog = SilenceWatchdog(graceInterval: 1)
        _ = watchdog.observe(peak: 0.5, sourceClaimsActive: true, now: start)
        watchdog.reset()
        XCTAssertFalse(watchdog.hasEverSeenAudio)
        XCTAssertEqual(watchdog.observe(peak: 0, sourceClaimsActive: true, now: start), .observing)
    }
}

final class MeterBallisticsTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 2_000_000)

    func testNormalisationAnchors() {
        XCTAssertEqual(MeterBallistics.normalised(amplitude: 1), 1, accuracy: 1e-5)
        XCTAssertEqual(MeterBallistics.normalised(amplitude: 0), 0)
        // -60 dB is the bottom of the scale.
        XCTAssertEqual(MeterBallistics.normalised(amplitude: 0.001), 0, accuracy: 1e-5)
        // -6 dB should sit near the top.
        XCTAssertEqual(MeterBallistics.normalised(amplitude: 0.5), 0.9, accuracy: 0.01)
    }

    func testAttackIsInstant() {
        var meter = MeterBallistics()
        meter.update(amplitude: 1, elapsed: 1.0 / 30, now: start)
        XCTAssertEqual(meter.displayLevel, 1, accuracy: 1e-5,
                       "a transient that is not shown immediately is a decoration, not a meter")
    }

    func testReleaseIsGradual() {
        var meter = MeterBallistics(releaseDBPerSecond: 20)
        meter.update(amplitude: 1, elapsed: 0.033, now: start)
        meter.update(amplitude: 0, elapsed: 0.5, now: start.addingTimeInterval(0.5))
        // 20 dB/s over half a second = 10 dB of a 60 dB scale.
        XCTAssertEqual(meter.displayLevel, 1 - (10.0 / 60.0), accuracy: 0.01)
    }

    func testLevelEventuallyReachesTheFloor() {
        var meter = MeterBallistics()
        meter.update(amplitude: 1, elapsed: 0.033, now: start)
        meter.update(amplitude: 0, elapsed: 10, now: start.addingTimeInterval(10))
        XCTAssertEqual(meter.displayLevel, 0, accuracy: 1e-5)
    }

    func testPeakHoldLingersThenFalls() {
        var meter = MeterBallistics(peakHoldSeconds: 1.0)
        meter.update(amplitude: 1, elapsed: 0.033, now: start)
        XCTAssertEqual(meter.peakLevel, 1, accuracy: 1e-5)

        meter.update(amplitude: 0, elapsed: 0.5, now: start.addingTimeInterval(0.5))
        XCTAssertEqual(meter.peakLevel, 1, accuracy: 1e-5, "peak must hold within the hold window")

        meter.update(amplitude: 0, elapsed: 0.5, now: start.addingTimeInterval(2.0))
        XCTAssertLessThan(meter.peakLevel, 1)
    }

    func testPeakNeverFallsBelowTheLevel() {
        var meter = MeterBallistics(peakHoldSeconds: 0)
        for step in 0..<200 {
            let now = start.addingTimeInterval(Double(step) * 0.033)
            meter.update(amplitude: Float.random(in: 0...1), elapsed: 0.033, now: now)
            XCTAssertGreaterThanOrEqual(meter.peakLevel, meter.displayLevel)
        }
    }

    func testValuesStayNormalised() {
        var meter = MeterBallistics()
        for step in 0..<500 {
            meter.update(amplitude: Float.random(in: 0...4), // deliberately over full scale
                         elapsed: 0.033,
                         now: start.addingTimeInterval(Double(step) * 0.033))
            XCTAssertTrue((0...1).contains(meter.displayLevel))
            XCTAssertTrue((0...1).contains(meter.peakLevel))
        }
    }

    func testNegativeElapsedDoesNotRaiseTheLevel() {
        var meter = MeterBallistics()
        meter.update(amplitude: 0.5, elapsed: 0.033, now: start)
        let before = meter.displayLevel
        meter.update(amplitude: 0, elapsed: -5, now: start)
        XCTAssertLessThanOrEqual(meter.displayLevel, before)
    }

    func testResetClearsBoth() {
        var stereo = StereoMeter()
        stereo.update(leftAmplitude: 1, rightAmplitude: 1, elapsed: 0.033, now: start)
        XCTAssertFalse(stereo.isSilent)
        stereo.reset()
        XCTAssertTrue(stereo.isSilent)
    }

    func testChannelsAreIndependent() {
        var stereo = StereoMeter()
        stereo.update(leftAmplitude: 1, rightAmplitude: 0, elapsed: 0.033, now: start)
        XCTAssertGreaterThan(stereo.left.displayLevel, 0.9)
        XCTAssertEqual(stereo.right.displayLevel, 0)
    }
}
