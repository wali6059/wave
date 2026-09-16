import Foundation
import CoreAudio
import AudioToolbox
import WaveCore

/// Live status of one application's route, as the UI needs to see it.
public struct RouteStatus: Equatable, Sendable {
    public var key: AppGroupKey
    public var state: RouteState
    public var resolution: DeviceResolution?
    /// Post-gain peaks, already drained from the render thread.
    public var meterLeft: Float = 0
    public var meterRight: Float = 0
    /// Pre-gain peak, used by the watchdog.
    public var inputPeak: Float = 0
    public var statistics = RenderStatisticsSnapshot()

    public init(key: AppGroupKey, state: RouteState, resolution: DeviceResolution? = nil) {
        self.key = key
        self.state = state
        self.resolution = resolution
    }
}

/// A drained pair of peaks for one route, plus the pre-gain peak the silence
/// watchdog reasons about.
public struct MeterSample: Equatable, Sendable {
    public var left: Float
    public var right: Float
    public var inputPeak: Float

    public init(left: Float, right: Float, inputPeak: Float) {
        self.left = left
        self.right = right
        self.inputPeak = inputPeak
    }
}

/// Orchestrates every route: which applications are intercepted, where their
/// audio goes, and what happens when any of that changes underneath.
///
/// The engine is the only owner of Core Audio resources and the only writer of
/// route state. It runs everything on one serial queue, so the ordering
/// problems that make audio teardown dangerous — a device-removed notification
/// arriving while a route is half-built, a fader move racing a restart — are
/// resolved by construction rather than by locking.
///
/// It knows nothing about SwiftUI. The UI observes it through `onStatusChange`
/// and drives it through the small command surface below.
public final class AudioRoutingEngine: @unchecked Sendable {

    // MARK: - One application's live resources

    private final class ActiveRoute {
        let key: AppGroupKey
        var state: RouteState = .idle
        var tapController: ProcessTapController?
        var renderer: RealtimeRenderer?
        var controlBlock: RealtimeControlBlock?
        var resolution: DeviceResolution?
        var watchdog = SilenceWatchdog()
        /// Process objects the current tap was built over. A change here means
        /// the tap has to be rebuilt to pick up a new helper process.
        var tappedProcessObjectIDs: [AudioObjectID] = []
        var lastInputPeak: Float = 0
        /// Last time render statistics were written to the log.
        var lastStatisticsLog: Date = .distantPast
        var loggedFirstAudio = false
        var meterLeft: Float = 0
        var meterRight: Float = 0

        init(key: AppGroupKey) { self.key = key }
    }

    // MARK: - Dependencies

    private let devices: AudioDeviceRegistry
    private let processes: AudioProcessDiscovery
    private let rules: RoutingRuleStore
    private let permissions: PermissionController
    private let diagnostics: Diagnostics

    private let queue = DispatchQueue(label: "app.wave.routing-engine")
    private var routes: [AppGroupKey: ActiveRoute] = [:]

    private var lastDevices: [OutputDeviceSnapshot] = []
    private var lastDefaultUID: String?
    private var meterTimer: DispatchSourceTimer?
    private var isRunning = false

    /// Published when route state, device resolution or the set of routes
    /// changes. Structural, and therefore infrequent.
    public var onStatusChange: (([AppGroupKey: RouteStatus]) -> Void)?

    /// Published at the meter rate with just the drained peaks.
    ///
    /// Deliberately separate from ``onStatusChange``: pushing a full status
    /// snapshot 30 times a second would make the UI rebuild every row's model
    /// at 30 Hz to animate two bars.
    public var onMeters: (([AppGroupKey: MeterSample]) -> Void)?

    public init(devices: AudioDeviceRegistry,
                processes: AudioProcessDiscovery,
                rules: RoutingRuleStore,
                permissions: PermissionController,
                diagnostics: Diagnostics = .shared) {
        self.devices = devices
        self.processes = processes
        self.rules = rules
        self.permissions = permissions
        self.diagnostics = diagnostics
    }

    deinit { shutdown() }

    // MARK: - Lifecycle

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true

            self.devices.addObserver { [weak self] snapshot, defaultUID in
                self?.queue.async { self?.handleDeviceChange(snapshot, defaultUID) }
            }
            self.processes.addObserver { [weak self] apps in
                self?.queue.async { self?.handleProcessChange(apps) }
            }
            // Granting permission should start the routes that were parked
            // waiting for it, and losing it should release them, without the
            // UI having to remember to ask.
            self.permissions.addObserver { [weak self] _ in
                self?.queue.async { self?.reconcileAllLocked() }
            }

            self.lastDevices = self.devices.devices
            self.lastDefaultUID = self.devices.defaultOutputUID
            self.startMeterTimer()
            self.diagnostics.info("Engine", "Started")
        }
    }

    /// Tears every route down and restores normal playback.
    ///
    /// Safe to call more than once and safe to call from `deinit`. This runs
    /// synchronously on purpose: at app termination it has to finish before the
    /// process exits, or taps could outlive us. In practice macOS destroys a
    /// dead process's taps anyway — and because muting is a property of the
    /// tap, audio comes back by itself even after a crash — but relying on that
    /// as the primary path would be sloppy.
    public func shutdown() {
        queue.sync {
            guard isRunning else { return }
            isRunning = false
            meterTimer?.cancel()
            meterTimer = nil

            for key in Array(routes.keys) {
                teardownRoute(key, reason: "engine shutdown")
            }
            routes.removeAll()
            diagnostics.info("Engine", "Shut down; all taps released and normal playback restored")
        }
    }

    // MARK: - Commands from the UI

    /// Applies the saved rule for an application, starting, restarting or
    /// stopping its route as required.
    public func applyRule(for key: AppGroupKey) {
        queue.async { [weak self] in self?.reconcile(key) }
    }

    /// Re-evaluates every application Wave knows about.
    public func reconcileAll() {
        queue.async { [weak self] in self?.reconcileAllLocked() }
    }

    private func reconcileAllLocked() {
        dispatchPrecondition(condition: .onQueue(queue))
        var keys = Set(routes.keys)
        for app in processes.apps { keys.insert(app.key) }
        for rule in rules.allRules { keys.insert(rule.appKey) }
        for key in keys { reconcile(key) }
    }

    /// Pushes a fader or mute change straight to the render thread.
    ///
    /// This deliberately does not go through ``reconcile(_:)``: changing a
    /// level must not restart audio. It is a single atomic store, so dragging a
    /// slider costs one instruction per frame of UI.
    public func updateLevel(for key: AppGroupKey, volume: Float, isMuted: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let gain = GainResolver.targetGain(position: volume,
                                               isMuted: isMuted,
                                               isRouteActive: self.routes[key]?.state.isLive ?? false)
            self.routes[key]?.controlBlock?.targetGain = gain

            // A rule that no longer needs interception (unity, unmuted, system
            // default) should give the application its untouched path back, and
            // one that now does need it should start.
            let rule = self.rules.effectiveRule(for: key)
            let wantsRouting = rule.requiresRouting
            let hasRoute = self.routes[key]?.state.holdsResources ?? false
            if wantsRouting != hasRoute { self.reconcile(key) }
        }
    }

    public func status(for key: AppGroupKey) -> RouteStatus? {
        queue.sync {
            guard let route = routes[key] else { return nil }
            return makeStatus(route)
        }
    }

    public var allStatuses: [AppGroupKey: RouteStatus] {
        queue.sync { snapshotStatuses() }
    }

    // MARK: - Reconciliation

    /// Brings one application's Core Audio state in line with its rule.
    private func reconcile(_ key: AppGroupKey) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isRunning else { return }

        let rule = rules.effectiveRule(for: key)
        let app = processes.app(for: key)

        // Nothing to intercept: no audio process, or a rule that asks for
        // nothing Wave has to be in the path for.
        guard let app, rule.requiresRouting else {
            if routes[key] != nil {
                teardownRoute(key, reason: app == nil ? "application stopped producing audio" : "rule no longer needs routing")
                routes.removeValue(forKey: key)
                publish()
            }
            return
        }

        guard permissions.canRoute else {
            // Refusing to build a route without permission is what keeps the
            // mixer honest: no strip ever shows itself as routing when macOS
            // will not let Wave capture anything.
            let route = routes[key] ?? ActiveRoute(key: key)
            teardownResources(route, reason: "system audio recording permission is not granted")
            route.state = .suspended(reason: .permissionMissing)
            routes[key] = route
            publish()
            return
        }

        let resolution = DeviceFallbackPolicy.resolve(rule: rule,
                                                      devices: lastDevices,
                                                      systemDefaultUID: lastDefaultUID)
        guard let destination = resolution.device else {
            let route = routes[key] ?? ActiveRoute(key: key)
            route.resolution = resolution
            teardownResources(route, reason: "no usable output device")
            route.state = .suspended(reason: .destinationUnavailable)
            routes[key] = route
            diagnostics.warning("Engine", "\(key) has no usable output device")
            publish()
            return
        }

        let existing = routes[key]
        let processesUnchanged = existing?.tappedProcessObjectIDs == app.processObjectIDs
        let destinationUnchanged = existing?.resolution?.device?.uid == destination.uid

        if let existing, existing.state.isLive, processesUnchanged, destinationUnchanged {
            // Already correct; just refresh the level and the resolution label.
            existing.resolution = resolution
            existing.controlBlock?.targetGain = GainResolver.targetGain(position: rule.volume,
                                                                        isMuted: rule.isMuted)
            publish()
            return
        }

        startRoute(key: key, app: app, rule: rule, resolution: resolution, destination: destination)
    }

    private func startRoute(key: AppGroupKey,
                            app: DiscoveredApp,
                            rule: RoutingRule,
                            resolution: DeviceResolution,
                            destination: OutputDeviceSnapshot) {
        dispatchPrecondition(condition: .onQueue(queue))

        // Always tear the previous incarnation down first. Two taps over the
        // same process, or two aggregates on the same device, is the fastest
        // way to a stuck-silent application.
        let route = routes[key] ?? ActiveRoute(key: key)
        teardownResources(route, reason: "restarting route")
        routes[key] = route

        // Resources are gone, so the route really is idle now. Saying so
        // explicitly matters: `.startRequested` is only a legal transition from
        // .idle or .failed, and a route being restarted after its device came
        // back is sitting in .suspended. Without this it would build its tap
        // and then never leave the suspended state.
        route.state = .idle
        _ = RouteLifecycle.apply(.startRequested, to: &route.state)
        route.resolution = resolution
        route.watchdog.reset()

        // Publish .preparing before the Core Audio calls, not after. Creating a
        // tap and starting IO on it can take a moment — and on a first run it
        // blocks until the permission prompt is answered — so a row that says
        // nothing until it is finished is indistinguishable from a fader that
        // does nothing at all.
        publish()

        guard let controlBlock = RealtimeControlBlock() else {
            route.state = .failed(message: "Could not allocate the render control block.")
            publish()
            return
        }
        controlBlock.targetGain = GainResolver.targetGain(position: rule.volume, isMuted: rule.isMuted)
        controlBlock.isActive = true
        route.controlBlock = controlBlock

        let tapController = ProcessTapController(diagnostics: diagnostics)
        route.tapController = tapController

        do {
            let prepared = try tapController.prepare(.init(processObjectIDs: app.processObjectIDs,
                                                           destinationDeviceUID: destination.uid,
                                                           label: app.displayName,
                                                           muteOriginalOutput: true))
            let renderer = try RealtimeRenderer(deviceID: prepared.aggregateDeviceID,
                                                plan: prepared.plan,
                                                controlBlock: controlBlock,
                                                diagnostics: diagnostics)
            route.renderer = renderer
            try renderer.start()

            route.tappedProcessObjectIDs = app.processObjectIDs
            _ = RouteLifecycle.apply(.prepareSucceeded, to: &route.state)
            diagnostics.notice("Engine",
                               "Routing \(app.displayName) -> \(destination.name) "
                               + "at \(VolumeCurve.percent(forPosition: rule.volume))%"
                               + (rule.isMuted ? " (muted)" : ""))
        } catch {
            let message = String(describing: error)
            diagnostics.error("Engine", "Could not route \(app.displayName): \(message)")
            teardownResources(route, reason: "route failed to start")
            _ = RouteLifecycle.apply(.prepareFailed(message: message), to: &route.state)
        }

        publish()
    }

    private func teardownRoute(_ key: AppGroupKey, reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let route = routes[key] else { return }
        _ = RouteLifecycle.apply(.stopRequested, to: &route.state)
        teardownResources(route, reason: reason)
        _ = RouteLifecycle.apply(.teardownCompleted, to: &route.state)
    }

    /// Releases the Core Audio objects for a route in the only safe order.
    ///
    /// Stop the IO proc, destroy the IO proc, destroy the aggregate, destroy
    /// the tap, and only then free the control block the callback was reading.
    /// Freeing the block earlier is a use-after-free on the audio thread; a
    /// dropped step leaves the tapped application muted with nothing rendering
    /// it, which is the worst outcome this code can produce.
    private func teardownResources(_ route: ActiveRoute, reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard route.renderer != nil || route.tapController != nil || route.controlBlock != nil else { return }

        route.controlBlock?.isActive = false

        route.renderer?.stop()
        route.renderer = nil

        route.tapController?.tearDown()
        route.tapController = nil

        route.controlBlock?.dispose()
        route.controlBlock = nil

        route.tappedProcessObjectIDs = []
        route.lastInputPeak = 0
        diagnostics.info("Engine", "Released resources for \(route.key): \(reason)")
    }

    // MARK: - Reacting to the system

    private func handleDeviceChange(_ snapshot: [OutputDeviceSnapshot], _ defaultUID: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        let previous = lastDevices
        let previousDefault = lastDefaultUID
        lastDevices = snapshot
        lastDefaultUID = defaultUID

        // Only disturb the routes whose destination actually changed. Restarting
        // everything on every hot-plug would glitch apps that were unaffected.
        let affected = DeviceFallbackPolicy.rulesNeedingRerouting(rules: rules.allRules,
                                                                  previous: previous,
                                                                  current: snapshot,
                                                                  previousDefaultUID: previousDefault,
                                                                  currentDefaultUID: defaultUID)
        guard !affected.isEmpty else {
            publish()
            return
        }
        diagnostics.notice("Engine", "Re-routing \(affected.count) rule(s) after a device change")
        for key in affected { reconcile(key) }
    }

    private func handleProcessChange(_ apps: [DiscoveredApp]) {
        dispatchPrecondition(condition: .onQueue(queue))

        let liveKeys = Set(apps.map(\.key))

        // An application that has gone away releases its route; its rule stays
        // on disk so the settings come back when it relaunches.
        let departed = routes.keys.filter { !liveKeys.contains($0) }
        for key in departed {
            teardownRoute(key, reason: "application exited")
            routes.removeValue(forKey: key)
        }

        for app in apps {
            let rule = rules.effectiveRule(for: app.key)
            let hasRoute = routes[app.key]?.state.holdsResources ?? false
            let processesChanged = routes[app.key]?.tappedProcessObjectIDs != app.processObjectIDs
            if rule.requiresRouting && (!hasRoute || processesChanged) {
                reconcile(app.key)
            }
        }
        publish()
    }

    // MARK: - Metering and the silence watchdog

    private func startMeterTimer() {
        dispatchPrecondition(condition: .onQueue(queue))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // 30 Hz is enough for a meter to look continuous and is two orders of
        // magnitude slower than the audio callback, which is the point: the
        // render thread never waits for the UI.
        timer.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in self?.drainMeters() }
        timer.resume()
        meterTimer = timer
    }

    private func drainMeters() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isRunning, !routes.isEmpty else { return }

        var samples: [AppGroupKey: MeterSample] = [:]
        samples.reserveCapacity(routes.count)
        var structuralChange = false

        for route in routes.values {
            guard let block = route.controlBlock else { continue }
            let peaks = block.drainPeaks()
            let inputPeak = block.drainInputPeak()
            route.lastInputPeak = inputPeak
            route.meterLeft = peaks.left
            route.meterRight = peaks.right
            samples[route.key] = MeterSample(left: peaks.left, right: peaks.right, inputPeak: inputPeak)

            guard route.state.isLive else { continue }

            let app = processes.app(for: route.key)
            switch route.watchdog.observe(peak: inputPeak,
                                          sourceClaimsActive: app?.isProducingOutput ?? false) {
            case .captureAppearsBlocked:
                permissions.noteCaptureAppearsBlocked()
                teardownResources(route, reason: "capture appears to be blocked by macOS")
                route.state = .suspended(reason: .permissionMissing)
                structuralChange = true
            case .healthy where inputPeak > SilenceWatchdog.silenceThreshold:
                permissions.noteCaptureSucceeded()
            case .healthy, .observing:
                break
            }
        }

        onMeters?(samples)
        if structuralChange { publish() }
        logRenderStatistics()
    }

    /// Periodically records what the render thread is actually doing.
    ///
    /// Without this the log can say "Routing Spotify at 73%" while the tap
    /// delivers nothing but silence, which reads as success and is the exact
    /// failure this app is supposed to be incapable of hiding. Buffer counts
    /// and the pre-gain peak are what distinguish "working", "capturing
    /// silence" and "callback never fired" from one another.
    private func logRenderStatistics() {
        dispatchPrecondition(condition: .onQueue(queue))
        let now = Date()

        for route in routes.values where route.state.isLive {
            guard let block = route.controlBlock else { continue }
            let statistics = block.statistics()

            // Say so the first time real audio arrives: that single line is
            // the difference between "the tap works" and "the tap is inert".
            if !route.loggedFirstAudio,
               statistics.buffersRendered > statistics.silentBuffers {
                route.loggedFirstAudio = true
                diagnostics.notice("Render",
                                   "\(route.key) is carrying audio through the tap")
            }

            guard now.timeIntervalSince(route.lastStatisticsLog) >= 5 else { continue }
            route.lastStatisticsLog = now

            let audible = statistics.buffersRendered - statistics.silentBuffers
            let claimsActive = processes.app(for: route.key)?.isProducingOutput ?? false
            diagnostics.info("Render",
                             "\(route.key): \(statistics.buffersRendered) buffers, "
                             + "\(audible) with audio, "
                             + "source says playing = \(claimsActive), "
                             + "underruns = \(statistics.underruns)")

            if statistics.buffersRendered > 0, audible == 0 {
                diagnostics.warning("Render",
                                    "\(route.key): the IO callback is running but every tapped "
                                    + "buffer is silent. The tap is not receiving this app's audio.")
            }
        }
    }

    // MARK: - Publishing

    private func makeStatus(_ route: ActiveRoute) -> RouteStatus {
        var status = RouteStatus(key: route.key, state: route.state, resolution: route.resolution)
        status.meterLeft = route.meterLeft
        status.meterRight = route.meterRight
        status.inputPeak = route.lastInputPeak
        status.statistics = route.controlBlock?.statistics() ?? RenderStatisticsSnapshot()
        return status
    }

    private func snapshotStatuses() -> [AppGroupKey: RouteStatus] {
        var result: [AppGroupKey: RouteStatus] = [:]
        for (key, route) in routes { result[key] = makeStatus(route) }
        return result
    }

    private func publish() {
        dispatchPrecondition(condition: .onQueue(queue))
        let snapshot = snapshotStatuses()
        onStatusChange?(snapshot)
    }
}
