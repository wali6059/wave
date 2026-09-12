import XCTest
@testable import WaveCore

final class RouteLifecycleTests: XCTestCase {

    func testHappyPath() {
        var state = RouteState.idle
        XCTAssertTrue(RouteLifecycle.apply(.startRequested, to: &state))
        XCTAssertEqual(state, .preparing)
        XCTAssertTrue(RouteLifecycle.apply(.prepareSucceeded, to: &state))
        XCTAssertEqual(state, .running)
        XCTAssertTrue(state.isLive)
        XCTAssertTrue(RouteLifecycle.apply(.stopRequested, to: &state))
        XCTAssertEqual(state, .tearingDown)
        XCTAssertTrue(RouteLifecycle.apply(.teardownCompleted, to: &state))
        XCTAssertEqual(state, .idle)
    }

    func testPreparationFailureIsRecoverable() {
        var state = RouteState.preparing
        XCTAssertTrue(RouteLifecycle.apply(.prepareFailed(message: "no device"), to: &state))
        XCTAssertEqual(state, .failed(message: "no device"))
        XCTAssertFalse(state.holdsResources, "a failed route must not be believed to own Core Audio objects")
        XCTAssertTrue(RouteLifecycle.apply(.startRequested, to: &state))
        XCTAssertEqual(state, .preparing)
    }

    // MARK: - The ordering guarantees that keep teardown safe

    /// Core Audio genuinely delivers notifications out of order: a
    /// device-removed callback can land after teardown has already started.
    /// Those must be no-ops, not crashes and not state corruption.
    func testInapplicableEventsAreNoOps() {
        var state = RouteState.tearingDown
        XCTAssertFalse(RouteLifecycle.apply(.destinationLost, to: &state))
        XCTAssertEqual(state, .tearingDown)

        state = .idle
        XCTAssertFalse(RouteLifecycle.apply(.prepareSucceeded, to: &state))
        XCTAssertEqual(state, .idle)

        state = .idle
        XCTAssertFalse(RouteLifecycle.apply(.ioStarted, to: &state))
        XCTAssertEqual(state, .idle)
    }

    /// The rule that stops Wave pushing audio into a device that is not there:
    /// a route suspended because its destination vanished must not be revived
    /// by an unrelated "source resumed" notification.
    func testSuspendedRouteOnlyResumesForItsOwnReason() {
        var state = RouteState.suspended(reason: .destinationUnavailable)
        XCTAssertFalse(RouteLifecycle.apply(.sourceResumed, to: &state))
        XCTAssertEqual(state, .suspended(reason: .destinationUnavailable))
        XCTAssertFalse(RouteLifecycle.apply(.permissionGranted, to: &state))
        XCTAssertEqual(state, .suspended(reason: .destinationUnavailable))
        XCTAssertTrue(RouteLifecycle.apply(.destinationRestored, to: &state))
        XCTAssertEqual(state, .preparing)
    }

    func testIdleSourceResumes() {
        var state = RouteState.suspended(reason: .sourceIdle)
        XCTAssertFalse(RouteLifecycle.apply(.destinationRestored, to: &state))
        XCTAssertTrue(RouteLifecycle.apply(.sourceResumed, to: &state))
        XCTAssertEqual(state, .preparing)
    }

    func testPermissionSuspensionResumesOnGrant() {
        var state = RouteState.suspended(reason: .permissionMissing)
        XCTAssertTrue(RouteLifecycle.apply(.permissionGranted, to: &state))
        XCTAssertEqual(state, .preparing)
    }

    func testDestinationLossOverridesAnyOtherSuspension() {
        var state = RouteState.suspended(reason: .sourceIdle)
        XCTAssertTrue(RouteLifecycle.apply(.destinationLost, to: &state))
        XCTAssertEqual(state, .suspended(reason: .destinationUnavailable))
    }

    func testAnySuspendedRouteCanBeStopped() {
        for reason in [SuspensionReason.destinationUnavailable, .sourceIdle, .permissionMissing] {
            var state = RouteState.suspended(reason: reason)
            XCTAssertTrue(RouteLifecycle.apply(.stopRequested, to: &state))
            XCTAssertEqual(state, .tearingDown)
        }
    }

    func testStoppingAPreparingRouteGoesStraightToTeardown() {
        var state = RouteState.preparing
        XCTAssertTrue(RouteLifecycle.apply(.stopRequested, to: &state))
        XCTAssertEqual(state, .tearingDown)
    }

    // MARK: - Resource-ownership invariant

    /// Everything that can own Core Audio objects must report so, or teardown
    /// will skip a tap and leave an application muted with nothing rendering
    /// it — the worst outcome this code can produce.
    func testStatesThatCanOwnResourcesSaySo() {
        XCTAssertFalse(RouteState.idle.holdsResources)
        XCTAssertFalse(RouteState.failed(message: "x").holdsResources)
        XCTAssertTrue(RouteState.preparing.holdsResources)
        XCTAssertTrue(RouteState.running.holdsResources)
        XCTAssertTrue(RouteState.suspended(reason: .sourceIdle).holdsResources)
        XCTAssertTrue(RouteState.tearingDown.holdsResources)
    }

    func testOnlyRunningIsLive() {
        XCTAssertTrue(RouteState.running.isLive)
        for state: RouteState in [.idle, .preparing, .tearingDown,
                                  .failed(message: "x"),
                                  .suspended(reason: .sourceIdle)] {
            XCTAssertFalse(state.isLive)
        }
    }

    /// Exhaustive sweep: no event may drive any state into a state that claims
    /// to hold resources when the previous one did not, except through the one
    /// path that actually creates them.
    func testResourcesAreOnlyAcquiredByStarting() {
        let states: [RouteState] = [.idle, .preparing, .running, .tearingDown,
                                    .failed(message: "x"),
                                    .suspended(reason: .destinationUnavailable),
                                    .suspended(reason: .sourceIdle),
                                    .suspended(reason: .permissionMissing)]
        let events: [RouteEvent] = [.startRequested, .prepareSucceeded, .prepareFailed(message: "x"),
                                    .ioStarted, .ioFailed(message: "x"), .destinationLost,
                                    .destinationRestored, .sourceWentIdle, .sourceResumed,
                                    .permissionLost, .permissionGranted, .stopRequested,
                                    .teardownCompleted]

        for state in states {
            for event in events {
                guard let next = RouteLifecycle.next(from: state, on: event) else { continue }
                if !state.holdsResources && next.holdsResources {
                    XCTAssertEqual(next, .preparing,
                                   "\(state) -> \(event) acquired resources without preparing")
                }
            }
        }
    }
}
