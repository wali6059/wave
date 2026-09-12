import Foundation

/// The state one application's route can be in.
///
/// Modelled explicitly because the failure modes here are the ones that leave
/// a Mac silent: a tap that was created but whose aggregate device failed, a
/// route torn down while the IO callback is mid-buffer, a device that vanished
/// between "resolve" and "start". Every transition is enumerated so the engine
/// cannot invent an order that skips cleanup.
public enum RouteState: Equatable, Sendable {
    /// No Core Audio resources exist for this application.
    case idle
    /// Tap and aggregate device are being created.
    case preparing
    /// Resources exist and the IO proc is running: audio is being intercepted,
    /// gained and rendered.
    case running
    /// Resources exist but the IO proc is stopped, e.g. the destination device
    /// went away and Wave is waiting for it to return.
    case suspended(reason: SuspensionReason)
    /// Setup orrunning failed. Carries a message fit to show a person.
    case failed(message: String)
    /// Resources are being released.
    case tearingDown

    public var isLive: Bool {
        if case .running = self { return true }
        return false
    }

    /// Whether Core Audio objects exist that must eventually be destroyed.
    public var holdsResources: Bool {
        switch self {
        case .idle, .failed: return false
        case .preparing, .running, .suspended, .tearingDown: return true
        }
    }
}

public enum SuspensionReason: String, Equatable, Sendable {
    /// The destination device disconnected.
    case destinationUnavailable
    /// The application stopped producing audio; the route is parked rather
    /// than destroyed so a resumed track does not have to rebuild everything.
    case sourceIdle
    /// System audio capture permission is not granted.
    case permissionMissing
}

/// Events that can move a route between states.
public enum RouteEvent: Equatable, Sendable {
    case startRequested
    case prepareSucceeded
    case prepareFailed(message: String)
    case ioStarted
    case ioFailed(message: String)
    case destinationLost
    case destinationRestored
    case sourceWentIdle
    case sourceResumed
    case permissionLost
    case permissionGranted
    case stopRequested
    case teardownCompleted
}

/// Pure transition table for ``RouteState``.
///
/// Returning `nil` means "this event does not apply in this state" — the engine
/// treats that as a no-op rather than a crash, because Core Audio notifications
/// genuinely do arrive out of order (a device-removed callback can land after
/// teardown has already begun).
public enum RouteLifecycle {

    public static func next(from state: RouteState, on event: RouteEvent) -> RouteState? {
        switch (state, event) {

        case (.idle, .startRequested):
            return .preparing
        case (.failed, .startRequested):
            return .preparing

        case (.preparing, .prepareSucceeded):
            return .running
        case (.preparing, .prepareFailed(let message)):
            return .failed(message: message)
        case (.preparing, .ioFailed(let message)):
            return .failed(message: message)
        case (.preparing, .stopRequested):
            return .tearingDown

        case (.running, .ioStarted):
            return .running
        case (.running, .ioFailed(let message)):
            return .failed(message: message)
        case (.running, .destinationLost):
            return .suspended(reason: .destinationUnavailable)
        case (.running, .sourceWentIdle):
            return .suspended(reason: .sourceIdle)
        case (.running, .permissionLost):
            return .suspended(reason: .permissionMissing)
        case (.running, .stopRequested):
            return .tearingDown

        // A suspended route only resumes on the event matching why it stopped.
        // Without this, a "source resumed" notification could restart a route
        // whose destination is still unplugged and push audio into nothing.
        case (.suspended(.destinationUnavailable), .destinationRestored):
            return .preparing
        case (.suspended(.sourceIdle), .sourceResumed):
            return .preparing
        case (.suspended(.permissionMissing), .permissionGranted):
            return .preparing
        case (.suspended, .stopRequested):
            return .tearingDown
        case (.suspended, .destinationLost):
            return .suspended(reason: .destinationUnavailable)
        case (.suspended, .permissionLost):
            return .suspended(reason: .permissionMissing)

        case (.tearingDown, .teardownCompleted):
            return .idle

        case (.idle, .stopRequested):
            return .idle
        case (.failed, .stopRequested):
            return .idle

        default:
            return nil
        }
    }

    /// Applies an event, leaving the state untouched when the transition does
    /// not apply.
    public static func apply(_ event: RouteEvent, to state: inout RouteState) -> Bool {
        guard let next = next(from: state, on: event) else { return false }
        state = next
        return true
    }
}
