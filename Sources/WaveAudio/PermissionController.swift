import Foundation
import AppKit
import WaveCore

/// Owns Wave's relationship with the macOS *System Audio Recording* privilege.
///
/// The important thing to understand about this privilege is that macOS
/// enforces it **silently**. With it denied, `AudioHardwareCreateProcessTap`,
/// `AudioHardwareCreateAggregateDevice` and `AudioDeviceStart` all return
/// `noErr`, the IO callback fires on schedule, and every tapped sample is zero.
/// There is no error to check. A mixer written against the return codes alone
/// would look completely healthy while doing nothing at all, which is exactly
/// the "functioning-looking mixer" this app must never show.
///
/// Wave therefore uses two independent signals:
///
/// 1. **TCC preflight**, when available. `TCCAccessPreflight` /
///    `TCCAccessRequest` are SPI in a private framework, reached by `dlopen`
///    rather than linked, so a missing or renamed symbol degrades instead of
///    failing to launch. This is what lets Wave explain the situation *before*
///    asking, and know the answer without starting audio.
/// 2. **The silence watchdog** in `WaveCore`, which needs no SPI at all: if a
///    process Core Audio reports as actively playing yields nothing but digital
///    silence through its tap, capture is being withheld. This is the backstop
///    that keeps the guarantee honest even if the SPI disappears in a future
///    macOS release.
///
/// Build with `-D WAVE_DISABLE_TCC_SPI` to drop signal 1 entirely and rely on
/// the watchdog alone.
public final class PermissionController: @unchecked Sendable {

    public enum Status: String, Sendable {
        /// Preflight says granted, or audio has demonstrably been captured.
        case authorized
        /// Preflight says denied, or the watchdog caught silent capture.
        case denied
        /// Never asked, or Wave cannot tell.
        case undetermined
    }

    /// Anchor for the Privacy pane that hosts the setting.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
    static let settingsFallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")

    private let diagnostics: Diagnostics
    private let lock = NSLock()
    private var _status: Status = .undetermined
    /// Set once the watchdog has caught capture producing nothing. Sticky for
    /// the session: once Wave knows capture is blocked, a later ambiguous
    /// preflight must not talk it back out of saying so.
    private var watchdogDenied = false

    private var observers: [(Status) -> Void] = []

    /// Registers an observer of permission changes and immediately delivers the
    /// current status. A list rather than a single slot so the routing engine
    /// and the view model cannot disconnect each other.
    public func addObserver(_ handler: @escaping (Status) -> Void) {
        lock.lock()
        observers.append(handler)
        let current = _status
        lock.unlock()
        handler(current)
    }

    public init(diagnostics: Diagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    public var status: Status {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    /// Whether Wave is allowed to present a mixer that claims to work.
    public var canRoute: Bool { status == .authorized }

    /// Human-readable copy shown before Wave asks for anything. Explaining
    /// first, and only asking when somebody presses the button, is the whole
    /// point of the onboarding screen.
    public static let rationale = """
        Wave needs permission to record system audio. That is the only way \
        macOS allows an app to capture what another app is playing, which is \
        what per-app volume and routing require.

        Wave records nothing to disk and sends nothing anywhere. Captured \
        audio travels from the tapped app, through Wave's gain stage, to the \
        output device you pick, and is then discarded.
        """

    // MARK: - Reading the current state

    @discardableResult
    public func refresh() -> Status {
        let resolved: Status
        if watchdogDenied {
            resolved = .denied
        } else {
            resolved = Self.preflight() ?? .undetermined
        }
        return apply(resolved)
    }

    /// Called by the routing engine when the watchdog concludes capture is
    /// producing nothing.
    public func noteCaptureAppearsBlocked() {
        lock.lock()
        let alreadyKnown = watchdogDenied
        watchdogDenied = true
        lock.unlock()

        if !alreadyKnown {
            diagnostics.error("Permission",
                              "A process reported as playing delivered only silence through its tap. "
                              + "Treating system audio recording as denied.")
        }
        apply(.denied)
    }

    /// Called when a tap demonstrably delivers audio, which proves the
    /// privilege is granted regardless of what preflight says.
    public func noteCaptureSucceeded() {
        lock.lock()
        watchdogDenied = false
        lock.unlock()
        apply(.authorized)
    }

    @discardableResult
    private func apply(_ status: Status) -> Status {
        lock.lock()
        let changed = _status != status
        _status = status
        // Copied out and called outside the lock: an observer that turns around
        // and reads `status` would otherwise deadlock on a non-recursive lock.
        let toNotify = changed ? observers : []
        lock.unlock()

        if changed {
            diagnostics.notice("Permission", "Status is now \(status.rawValue)")
            for observer in toNotify { observer(status) }
        }
        return status
    }

    // MARK: - Requesting

    /// Presents the system prompt. Must only ever be called from an explicit
    /// user action — Wave calls it from the onboarding screen's button and
    /// nowhere else.
    public func request(completion: @escaping (Status) -> Void) {
        guard let request = Self.requestSPI else {
            // Without the SPI the only way to make macOS ask is to start
            // audio. The engine does that on the next routing attempt and the
            // watchdog reports the outcome.
            diagnostics.notice("Permission",
                               "Permission SPI unavailable; the prompt will appear when routing first starts.")
            let status = apply(.undetermined)
            completion(status)
            return
        }

        diagnostics.notice("Permission", "Requesting system audio recording access")
        request("kTCCServiceAudioCapture" as CFString, nil) { [weak self] granted in
            guard let self else { return }
            if granted {
                self.lock.lock(); self.watchdogDenied = false; self.lock.unlock()
            }
            let status = self.apply(granted ? .authorized : .denied)
            DispatchQueue.main.async { completion(status) }
        }
    }

    /// Opens the exact pane the person needs. Wave still spells out the path in
    /// the UI, because a deep link that fails to open in a future macOS leaves
    /// somebody stuck with no instructions.
    @MainActor
    public static func openSystemSettings() {
        if let url = settingsURL, NSWorkspace.shared.open(url) { return }
        if let fallback = settingsFallbackURL { NSWorkspace.shared.open(fallback) }
    }

    /// The literal steps, kept next to the deep link so the two cannot drift.
    public static let manualInstructions = """
        Open System Settings ▸ Privacy & Security ▸ System Audio Recording, \
        then switch Wave on. If Wave is already listed and switched on, switch \
        it off and on again, then quit and reopen Wave.
        """

    // MARK: - TCC SPI

    private static func preflight() -> Status? {
        guard let preflight = preflightSPI else { return nil }
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .undetermined
        }
    }

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    #if WAVE_DISABLE_TCC_SPI

    private static let preflightSPI: PreflightFunction? = nil
    private static let requestSPI: RequestFunction? = nil

    #else

    private static let tccHandle: UnsafeMutableRawPointer? = {
        let path = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
        guard let handle = dlopen(path, RTLD_NOW) else {
            Diagnostics.shared.warning("Permission", "Could not open TCC.framework; falling back to the watchdog only")
            return nil
        }
        return handle
    }()

    private static let preflightSPI: PreflightFunction? = {
        guard let tccHandle, let symbol = dlsym(tccHandle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunction.self)
    }()

    private static let requestSPI: RequestFunction? = {
        guard let tccHandle, let symbol = dlsym(tccHandle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestFunction.self)
    }()

    #endif
}
