import XCTest
@testable import WaveCore

final class RenderPlanBuilderTests: XCTestCase {

    private func format(_ channels: Int,
                        rate: Double = 48_000,
                        interleaved: Bool = false,
                        float: Bool = true) -> AudioFormatSpec {
        AudioFormatSpec(sampleRate: rate, channelCount: channels,
                        isInterleaved: interleaved, isFloat32: float)
    }

    // MARK: - Acceptance

    func testStereoToStereoIsPassThrough() throws {
        let plan = try XCTUnwrap(try? RenderPlanBuilder.makePlan(input: format(2),
                                                                 output: format(2)).get())
        XCTAssertEqual(plan.channelTaps, [.copy(0), .copy(1)])
    }

    // MARK: - Rejection

    /// Reinterpreting an unexpected format is the difference between quiet
    /// audio and full-scale noise in somebody's headphones, so Wave refuses.
    func testNonFloatInputIsRejected() {
        let result = RenderPlanBuilder.makePlan(input: format(2, float: false), output: format(2))
        XCTAssertEqual(result.failure, .inputNotFloat32)
    }

    func testNonFloatOutputIsRejected() {
        let result = RenderPlanBuilder.makePlan(input: format(2), output: format(2, float: false))
        XCTAssertEqual(result.failure, .outputNotFloat32)
    }

    /// Both sides come from one aggregate device, so a rate mismatch means an
    /// assumption has broken. Resampling in the callback would paper over it.
    func testSampleRateMismatchIsRejected() {
        let result = RenderPlanBuilder.makePlan(input: format(2, rate: 44_100),
                                                output: format(2, rate: 48_000))
        XCTAssertEqual(result.failure, .sampleRateMismatch(input: 44_100, output: 48_000))
    }

    func testEmptyChannelCountsAreRejected() {
        XCTAssertEqual(RenderPlanBuilder.makePlan(input: format(0), output: format(2)).failure,
                       .emptyInput)
        XCTAssertEqual(RenderPlanBuilder.makePlan(input: format(2), output: format(0)).failure,
                       .emptyOutput)
    }

    func testAbsurdChannelCountsAreRejected() {
        let result = RenderPlanBuilder.makePlan(input: format(2), output: format(1024))
        XCTAssertEqual(result.failure, .channelCountUnsupported(input: 2, output: 1024))
    }

    func testMaxChannelsIsAccepted() {
        let result = RenderPlanBuilder.makePlan(input: format(2),
                                                output: format(RenderPlanBuilder.maxChannels))
        XCTAssertNil(result.failure)
    }

    // MARK: - Channel mapping

    func testMonoFansOutToTheFrontPair() {
        let taps = RenderPlanBuilder.channelTaps(inputChannels: 1, outputChannels: 2)
        XCTAssertEqual(taps, [.copy(0), .copy(0)],
                       "a mono source must not end up in one ear")
    }

    func testMonoIntoMono() {
        XCTAssertEqual(RenderPlanBuilder.channelTaps(inputChannels: 1, outputChannels: 1), [.copy(0)])
    }

    func testMonoIntoSurroundLeavesRearChannelsSilent() {
        let taps = RenderPlanBuilder.channelTaps(inputChannels: 1, outputChannels: 6)
        XCTAssertEqual(taps[0], .copy(0))
        XCTAssertEqual(taps[1], .copy(0))
        for index in 2..<6 {
            XCTAssertTrue(taps[index].isSilent, "channel \(index) should be silent, not synthesised")
        }
    }

    func testStereoIntoMonoFoldsDown() {
        let taps = RenderPlanBuilder.channelTaps(inputChannels: 2, outputChannels: 1)
        XCTAssertEqual(taps, [.mix(0, 1)])
    }

    /// Equal-weight fold-down cannot exceed the loudest contributing channel,
    /// so it cannot clip.
    func testFoldDownCannotExceedFullScale() {
        let tap = RenderPlanBuilder.channelTaps(inputChannels: 2, outputChannels: 1)[0]
        let worstCase = 1.0 * tap.gainA + 1.0 * tap.gainB
        XCTAssertLessThanOrEqual(worstCase, 1.0)
    }

    func testStereoIntoSurroundUsesTheFrontPairOnly() {
        let taps = RenderPlanBuilder.channelTaps(inputChannels: 2, outputChannels: 8)
        XCTAssertEqual(taps[0], .copy(0))
        XCTAssertEqual(taps[1], .copy(1))
        XCTAssertTrue(taps[2...].allSatisfy(\.isSilent))
    }

    func testMoreInputChannelsThanOutputTakesTheFirstOnes() {
        let taps = RenderPlanBuilder.channelTaps(inputChannels: 6, outputChannels: 2)
        XCTAssertEqual(taps, [.copy(0), .copy(1)])
    }

    func testEveryMappingProducesExactlyOneTapPerOutputChannel() {
        for input in 1...8 {
            for output in 1...8 {
                let taps = RenderPlanBuilder.channelTaps(inputChannels: input, outputChannels: output)
                XCTAssertEqual(taps.count, output, "\(input)->\(output) produced the wrong tap count")
            }
        }
    }

    /// No mapping may ever reference a channel the source does not have; doing
    /// so would read past the end of the input buffer on the audio thread.
    func testNoMappingReferencesAChannelThatDoesNotExist() {
        for input in 1...8 {
            for output in 1...8 {
                for tap in RenderPlanBuilder.channelTaps(inputChannels: input, outputChannels: output) {
                    XCTAssertLessThan(Int(tap.sourceA), input)
                    XCTAssertLessThan(Int(tap.sourceB), input)
                }
            }
        }
    }

    func testInterleavingIsCarriedIntoThePlanNotRejected() throws {
        let plan = try XCTUnwrap(try? RenderPlanBuilder.makePlan(input: format(2, interleaved: true),
                                                                 output: format(2, interleaved: false)).get())
        XCTAssertTrue(plan.input.isInterleaved)
        XCTAssertFalse(plan.output.isInterleaved)
    }
}

private extension Result where Failure == FormatIncompatibility {
    var failure: FormatIncompatibility? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
