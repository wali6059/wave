import XCTest
@testable import WaveCore

/// Exercises the lock-free cells the render thread and the UI share.
///
/// These are the only mutable state crossing the real-time boundary, so their
/// semantics — relaxed atomics, raise-don't-overwrite peaks, drain-and-clear —
/// are worth pinning down directly rather than inferring from the mixer's
/// behaviour.
final class RealtimeControlBlockTests: XCTestCase {

    private var block: RealtimeControlBlock!

    override func setUpWithError() throws {
        block = try XCTUnwrap(RealtimeControlBlock())
    }

    override func tearDown() {
        block?.dispose()
        block = nil
        super.tearDown()
    }

    func testStartsSilentAndInactive() {
        XCTAssertEqual(block.targetGain, 0)
        XCTAssertFalse(block.isActive)
    }

    func testGainRoundTrips() {
        block.targetGain = 0.42
        XCTAssertEqual(block.targetGain, 0.42, accuracy: 1e-6)
    }

    /// Clamping lives in C so the render thread can trust the value it loads
    /// without re-checking it.
    func testGainIsClampedAtTheBoundary() {
        block.targetGain = 5
        XCTAssertEqual(block.targetGain, 1)
        block.targetGain = -5
        XCTAssertEqual(block.targetGain, 0)
    }

    func testActiveFlagRoundTrips() {
        block.isActive = true
        XCTAssertTrue(block.isActive)
        block.isActive = false
        XCTAssertFalse(block.isActive)
    }

    func testDrainingPeaksClearsThem() {
        XCTAssertEqual(block.drainPeaks().left, 0)
        XCTAssertEqual(block.drainInputPeak(), 0)
    }

    func testDisposeIsIdempotent() {
        block.dispose()
        block.dispose()
    }

    func testStatisticsStartAtZero() {
        let statistics = block.statistics()
        XCTAssertEqual(statistics.buffersRendered, 0)
        XCTAssertEqual(statistics.framesRendered, 0)
        XCTAssertEqual(statistics.underruns, 0)
        XCTAssertEqual(statistics.clampedSamples, 0)
        XCTAssertEqual(statistics.silentBuffers, 0)
    }

    /// A control thread hammering the gain while a "render thread" reads it
    /// must never observe a torn value — every read has to be one of the
    /// values actually written.
    func testConcurrentGainWritesAreNeverTorn() {
        let written: [Float] = [0.0, 0.25, 0.5, 0.75, 1.0]
        let deadline = Date().addingTimeInterval(0.5)
        let reader = expectation(description: "reader finished")

        DispatchQueue.global().async {
            while Date() < deadline {
                let value = self.block.targetGain
                XCTAssertTrue(written.contains { abs($0 - value) < 1e-6 },
                              "observed a value that was never written: \(value)")
            }
            reader.fulfill()
        }

        while Date() < deadline {
            block.targetGain = written.randomElement()!
        }
        wait(for: [reader], timeout: 5)
    }

    func testManyBlocksCanCoexist() {
        var blocks: [RealtimeControlBlock] = []
        for index in 0..<32 {
            guard let extra = RealtimeControlBlock() else { return XCTFail("allocation failed") }
            extra.targetGain = Float(index) / 32
            blocks.append(extra)
        }
        for (index, extra) in blocks.enumerated() {
            XCTAssertEqual(extra.targetGain, Float(index) / 32, accuracy: 1e-6,
                           "blocks must not share storage")
        }
        blocks.forEach { $0.dispose() }
    }
}

final class DiagnosticsTests: XCTestCase {

    func testRingBufferEvictsOldestEntries() {
        let diagnostics = Diagnostics(capacity: 10)
        for index in 0..<25 {
            diagnostics.info("Test", "entry \(index)")
        }
        let entries = diagnostics.recent
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(entries.first?.message, "entry 15")
        XCTAssertEqual(entries.last?.message, "entry 24")
    }

    func testClear() {
        let diagnostics = Diagnostics(capacity: 5)
        diagnostics.error("Test", "boom")
        XCTAssertEqual(diagnostics.recent.count, 1)
        diagnostics.clear()
        XCTAssertTrue(diagnostics.recent.isEmpty)
    }

    func testExportIncludesLevelAndCategory() {
        let diagnostics = Diagnostics(capacity: 5)
        diagnostics.warning("Devices", "AirPods went away")
        let text = diagnostics.exportText()
        XCTAssertTrue(text.contains("[warning]"))
        XCTAssertTrue(text.contains("Devices"))
        XCTAssertTrue(text.contains("AirPods went away"))
    }

    func testConcurrentLoggingDoesNotCrashOrExceedCapacity() {
        let diagnostics = Diagnostics(capacity: 100)
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            diagnostics.info("Test", "entry \(index)")
        }
        XCTAssertLessThanOrEqual(diagnostics.recent.count, 100)
    }
}
