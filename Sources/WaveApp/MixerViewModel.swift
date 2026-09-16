import Foundation
import SwiftUI
import AppKit
import Combine
import WaveCore
import WaveAudio

/// One row of the mixer, assembled from four independent sources: what Core
/// Audio says is playing, what the user saved, what the routing engine managed
/// to do about it, and the meter.
struct MixerChannel: Identifiable, Equatable {
    var key: AppGroupKey
    var name: String
    var bundleIdentifier: String?
    var bundleURL: URL?
    /// Currently producing audio.
    var isProducingOutput: Bool
    /// The process exists, whether or not it is making noise right now.
    var isRunning: Bool
    var rule: RoutingRule
    var routeState: RouteState
    var resolution: DeviceResolution?
    var meter = StereoMeter()
    var isSystemSounds: Bool
    var kind: DiscoveredApp.Kind = .application

    /// True when the user has asked for something Wave has to intercept to
    /// deliver — a level other than 100%, a mute, or a specific device.
    var wantsRouting: Bool { rule.requiresRouting }

    /// The case that must never be silent: the user has set a level, but no
    /// audio is being intercepted, so the fader is decorative.
    var isSettingIgnored: Bool { wantsRouting && !routeState.isLive }

    var id: String { key.rawValue }

    /// The line shown under the app name when something needs saying.
    ///
    /// The `.idle` case is the important one. A fader set to 40% on a route
    /// that never started looks exactly like a fader that is working, and that
    /// is the single thing this app must never do. If Wave is not intercepting
    /// the audio, the row says so.
    var statusMessage: String? {
        func fallbackNote() -> String? {
            guard let resolution, case .fellBack(let device, _, let missingName) = resolution else {
                return nil
            }
            return "\(missingName ?? "Saved device") disconnected · using \(device.name)"
        }

        switch routeState {
        case .failed(let message):
            return message
        case .suspended(.destinationUnavailable):
            return fallbackNote() ?? "Output disconnected"
        case .suspended(.permissionMissing):
            return "Not routing · system audio recording permission is missing"
        case .suspended(.sourceIdle):
            return nil
        case .preparing:
            return "Starting…"
        case .idle, .tearingDown:
            return wantsRouting ? "Not routing · this level is not being applied" : fallbackNote()
        case .running:
            return fallbackNote()
        }
    }

    var isDegraded: Bool {
        if case .failed = routeState { return true }
        if case .suspended = routeState { return true }
        if isSettingIgnored { return true }
        return resolution?.isDegraded ?? false
    }
}

/// Everything the SwiftUI layer talks to.
///
/// Deliberately the only place where the audio components and SwiftUI meet.
/// The engine below has no idea this exists; it publishes plain values on its
/// own queue and this type hops them to the main actor. That separation is what
/// keeps a slow view update from ever being able to affect audio.
@MainActor
final class MixerViewModel: ObservableObject {

    @Published private(set) var activeChannels: [MixerChannel] = []
    @Published private(set) var savedChannels: [MixerChannel] = []
    /// Daemons and bare executables. Real, occasionally useful, almost never
    /// what somebody opened the mixer for — so they live behind a disclosure.
    @Published private(set) var systemChannels: [MixerChannel] = []
    @Published var isShowingSystemProcesses = false
    /// True when permission arrived mid-session and no tap has yet carried a
    /// single non-silent sample. Clears itself the moment one does.
    @Published private(set) var needsRelaunchAfterGrant = false
    @Published private(set) var outputDevices: [OutputDeviceSnapshot] = []
    @Published private(set) var permissionStatus: PermissionController.Status = .undetermined
    @Published private(set) var masterVolume: Float = 1
    @Published private(set) var masterMuted = false
    @Published private(set) var masterDeviceName: String?
    @Published private(set) var masterAvailable = false
    @Published var isShowingDiagnostics = false

    let diagnostics = Diagnostics.shared
    private let devices: AudioDeviceRegistry
    private let processes: AudioProcessDiscovery
    private let permissions: PermissionController
    private let master: MasterOutputController
    private let rules: RoutingRuleStore
    private let engine: AudioRoutingEngine

    private var channels: [AppGroupKey: MixerChannel] = [:]
    private var statuses: [AppGroupKey: RouteStatus] = [:]
    /// Latest drained peaks, refreshed by the engine and consumed by the meter
    /// tick. Kept apart from `statuses` so a level change never rebuilds a row.
    private var latestMeters: [AppGroupKey: MeterSample] = [:]
    private var iconCache: [String: NSImage] = [:]

    private var meterTimer: Timer?
    private var refreshTimer: Timer?
    private var saveWorkItem: DispatchWorkItem?
    private var lastMeterTick = Date()
    private var started = false
    private var hasObservedCapturedAudio = false

    /// Honours Reduce Motion by slowing the meters right down instead of
    /// animating at 30 Hz. The information is still there; it just stops
    /// flickering.
    private var meterInterval: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.25 : 1.0 / 30.0
    }

    init() {
        let storage: RuleFileStorage
        do {
            storage = FileRuleStorage(fileURL: try FileRuleStorage.defaultLocation())
        } catch {
            // A missing Application Support directory should not stop Wave
            // launching; it just means this session's changes are not saved.
            Diagnostics.shared.error("Rules", "Could not locate the rules file: \(error). Using memory only.")
            storage = InMemoryRuleStorage()
        }

        // Built as locals first and then assigned, so the engine is handed the
        // same instances the view model keeps without reading `self` while it
        // is still being initialised.
        let devices = AudioDeviceRegistry()
        let processes = AudioProcessDiscovery()
        let permissions = PermissionController()
        let rules = RoutingRuleStore(storage: storage)

        self.devices = devices
        self.processes = processes
        self.permissions = permissions
        self.master = MasterOutputController()
        self.rules = rules
        self.engine = AudioRoutingEngine(devices: devices,
                                         processes: processes,
                                         rules: rules,
                                         permissions: permissions)
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        switch rules.load() {
        case .loaded(let count):
            diagnostics.info("Rules", "Loaded \(count) saved rule(s)")
        case .empty:
            diagnostics.info("Rules", "No saved rules yet")
        case .recoveredFromCorruptFile(let message):
            diagnostics.error("Rules", message)
        }

        permissions.addObserver { [weak self] status in
            Task { @MainActor in
                self?.permissionStatus = status
                self?.rebuildChannels()
            }
        }
        devices.addObserver { [weak self] snapshot, _ in
            Task { @MainActor in
                self?.outputDevices = snapshot
                self?.rebuildChannels()
            }
        }
        processes.addObserver { [weak self] _ in
            Task { @MainActor in self?.rebuildChannels() }
        }
        engine.onStatusChange = { [weak self] statuses in
            Task { @MainActor in
                self?.statuses = statuses
                self?.rebuildChannels()
            }
        }
        engine.onMeters = { [weak self] samples in
            Task { @MainActor in self?.accumulateMeters(samples) }
        }
        master.addObserver { [weak self] in
            Task { @MainActor in self?.refreshMaster() }
        }

        permissions.refresh()
        permissionStatus = permissions.status
        devices.start()
        processes.start()
        master.start()
        engine.start()

        outputDevices = devices.devices
        refreshMaster()
        rebuildChannels()

        // Core Audio does not notify on every transition that matters to the
        // mixer — a process that starts playing does not change the process
        // *list* — so a slow poll backs the notifications up.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.processes.refreshNow()
                self?.refreshMaster()
            }
        }
        startMeterTimer()

        engine.reconcileAll()
    }

    func shutdown() {
        meterTimer?.invalidate(); meterTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        saveWorkItem?.cancel(); saveWorkItem = nil
        persistNow()
        engine.shutdown()
        master.stop()
        processes.stop()
        devices.stop()
        diagnostics.info("App", "Wave shut down cleanly")
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        lastMeterTick = Date()
        meterTimer = Timer.scheduledTimer(withTimeInterval: meterInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMeters() }
        }
    }

    // MARK: - Permission

    var canShowMixer: Bool { permissionStatus == .authorized }

    /// Only ever called from the onboarding button.
    func requestPermission() {
        permissions.request { [weak self] status in
            Task { @MainActor in
                self?.permissionStatus = status
                if status == .authorized { self?.engine.reconcileAll() }
                self?.refreshRelaunchAdvice()
            }
        }
    }

    /// macOS decides what an audio client may capture largely when that client
    /// connects to coreaudiod. A grant that lands afterwards does not reliably
    /// reach an existing connection, so taps are created, IO runs, every call
    /// returns success, and nothing is captured. Relaunching is the fix.
    private func refreshRelaunchAdvice() {
        let advise = permissions.grantedDuringThisSession && !hasObservedCapturedAudio
        guard advise != needsRelaunchAfterGrant else { return }
        needsRelaunchAfterGrant = advise
        if advise {
            diagnostics.notice("Permission",
                               "Permission was granted after launch. Wave must be relaunched "
                               + "before its taps can capture anything.")
        }
    }

    /// Starts a fresh instance and exits this one.
    func relaunch() {
        shutdown()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    func openPermissionSettings() {
        PermissionController.openSystemSettings()
    }

    func recheckPermission() {
        permissionStatus = permissions.refresh()
        if permissionStatus == .authorized { engine.reconcileAll() }
        refreshRelaunchAdvice()
    }

    // MARK: - Commands

    func setVolume(_ position: Float, for key: AppGroupKey) {
        let rule = rules.update(key) { $0.volume = min(max(position, 0), 1) }
        channels[key]?.rule = rule
        engine.updateLevel(for: key, volume: rule.volume, isMuted: rule.isMuted)
        publish()
        schedulePersist()
    }

    func toggleMute(for key: AppGroupKey) {
        let rule = rules.update(key) { $0.isMuted.toggle() }
        channels[key]?.rule = rule
        engine.updateLevel(for: key, volume: rule.volume, isMuted: rule.isMuted)
        publish()
        schedulePersist()
    }

    func setOutput(_ device: OutputDeviceSnapshot?, for key: AppGroupKey) {
        let rule = rules.update(key) {
            $0.outputDeviceUID = device?.uid
            $0.outputDeviceName = device?.name
        }
        channels[key]?.rule = rule
        engine.applyRule(for: key)
        publish()
        schedulePersist()
    }

    /// Removes a saved rule entirely, returning the application to untouched
    /// system playback.
    func forget(_ key: AppGroupKey) {
        rules.remove(key)
        engine.applyRule(for: key)
        channels.removeValue(forKey: key)
        publish()
        schedulePersist()
    }

    func setMasterVolume(_ value: Float) {
        master.volume = value
        masterVolume = value
    }

    func toggleMasterMute() {
        master.isMuted.toggle()
        masterMuted = master.isMuted
    }

    private func refreshMaster() {
        masterAvailable = master.isAvailable
        masterVolume = master.volume ?? 1
        masterMuted = master.isMuted
        masterDeviceName = master.deviceName
    }

    // MARK: - Persistence

    private func schedulePersist() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.persistNow() }
        }
        saveWorkItem = work
        // Dragging a fader produces a continuous stream of changes; writing the
        // rules file on each one would be pointless disk traffic.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func persistNow() {
        do {
            try rules.save()
        } catch {
            diagnostics.error("Rules", "Could not save rules: \(error.localizedDescription)")
        }
    }

    // MARK: - Building the rows

    private func rebuildChannels() {
        let discovered = processes.apps
        let discoveredByKey = Dictionary(uniqueKeysWithValues: discovered.map { ($0.key, $0) })

        var next: [AppGroupKey: MixerChannel] = [:]

        for app in discovered {
            let rule = rules.effectiveRule(for: app.key)
            let status = statuses[app.key]
            var channel = channels[app.key] ?? MixerChannel(key: app.key,
                                                            name: app.displayName,
                                                            bundleIdentifier: app.bundleIdentifier,
                                                            bundleURL: app.bundleURL,
                                                            isProducingOutput: app.isProducingOutput,
                                                            isRunning: true,
                                                            rule: rule,
                                                            routeState: status?.state ?? .idle,
                                                            resolution: status?.resolution,
                                                            isSystemSounds: app.isSystemSounds,
                                                            kind: app.kind)
            channel.name = app.displayName
            channel.kind = app.kind
            channel.bundleIdentifier = app.bundleIdentifier
            channel.bundleURL = app.bundleURL
            channel.isProducingOutput = app.isProducingOutput
            channel.isRunning = true
            channel.rule = rule
            channel.routeState = status?.state ?? .idle
            channel.resolution = status?.resolution
            next[app.key] = channel
        }

        // Saved rules for applications that are not running right now. Shown so
        // the settings are visible and editable before the app launches, which
        // is the whole point of persisting them.
        for rule in rules.allRules where discoveredByKey[rule.appKey] == nil {
            var channel = channels[rule.appKey] ?? MixerChannel(key: rule.appKey,
                                                                name: Self.friendlyName(for: rule.appKey),
                                                                bundleIdentifier: rule.appKey.rawValue,
                                                                bundleURL: Self.bundleURL(for: rule.appKey),
                                                                isProducingOutput: false,
                                                                isRunning: false,
                                                                rule: rule,
                                                                routeState: .idle,
                                                                resolution: nil,
                                                                isSystemSounds: rule.appKey.isSystemSounds)
            channel.rule = rule
            channel.isProducingOutput = false
            channel.isRunning = false
            channel.routeState = .idle
            channel.meter.reset()
            next[rule.appKey] = channel
        }

        channels = next
        publish()
    }

    private func publish() {
        let all = channels.values

        func isLive(_ channel: MixerChannel) -> Bool {
            channel.isRunning && (channel.isProducingOutput || channel.routeState.holdsResources)
        }

        // Background daemons are separated out first, whatever they are doing.
        // A dozen of them above Spotify is the reason the list needed scrolling.
        let foreground = all.filter { $0.kind != .backgroundProcess }

        activeChannels = foreground.filter(isLive).sorted(by: Self.order)

        savedChannels = foreground
            .filter { !isLive($0) }
            .filter { $0.isRunning || rules.rule(for: $0.key) != nil }
            .sorted(by: Self.order)

        systemChannels = all
            .filter { $0.kind == .backgroundProcess }
            .sorted(by: Self.order)
    }

    private static func order(_ lhs: MixerChannel, _ rhs: MixerChannel) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.isProducingOutput != rhs.isProducingOutput { return lhs.isProducingOutput }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    // MARK: - Meters

    /// Folds incoming peaks into the pending sample by taking the maximum.
    ///
    /// The engine drains the render thread's peaks at a fixed 30 Hz, but the UI
    /// tick can be slower — Reduce Motion drops it to 4 Hz. Replacing rather
    /// than accumulating would throw away every transient that landed between
    /// two UI frames, so a quiet meter under Reduce Motion would be a lie
    /// rather than a calmer truth.
    private func accumulateMeters(_ samples: [AppGroupKey: MeterSample]) {
        if !hasObservedCapturedAudio,
           samples.values.contains(where: { $0.inputPeak > SilenceWatchdog.silenceThreshold }) {
            // A tap has delivered real audio, so capture is genuinely working
            // and any relaunch advice is now wrong. Retract it.
            hasObservedCapturedAudio = true
            needsRelaunchAfterGrant = false
            diagnostics.notice("Permission", "Capture confirmed working; no relaunch needed")
        }
        for (key, sample) in samples {
            guard let existing = latestMeters[key] else {
                latestMeters[key] = sample
                continue
            }
            latestMeters[key] = MeterSample(left: max(existing.left, sample.left),
                                            right: max(existing.right, sample.right),
                                            inputPeak: max(existing.inputPeak, sample.inputPeak))
        }
    }

    private func tickMeters() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastMeterTick)
        lastMeterTick = now

        var changed = false
        for key in Array(channels.keys) {
            guard var channel = channels[key] else { continue }
            let sample = latestMeters[key]
            // A row with no live route decays to the floor rather than
            // freezing on its last value.
            if sample == nil && channel.meter.isSilent { continue }
            channel.meter.update(leftAmplitude: sample?.left ?? 0,
                                 rightAmplitude: sample?.right ?? 0,
                                 elapsed: elapsed,
                                 now: now)
            channels[key] = channel
            changed = true
        }
        // Peaks are drained by the engine, so each sample must be consumed
        // once; leaving them would hold the meter up on a stale transient.
        latestMeters.removeAll(keepingCapacity: true)

        if changed { publish() }
    }

    // MARK: - Presentation helpers

    func icon(for channel: MixerChannel) -> NSImage {
        if channel.isSystemSounds {
            let image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                accessibilityDescription: "System sounds")
            return image ?? NSWorkspace.shared.icon(for: .applicationBundle)
        }
        if let url = channel.bundleURL {
            if let cached = iconCache[url.path] { return cached }
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: 32, height: 32)
            iconCache[url.path] = image
            return image
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    /// The device a channel is actually playing through, for the picker label.
    func destinationLabel(for channel: MixerChannel) -> String {
        if let resolution = channel.resolution, let device = resolution.device {
            return device.name
        }
        if let uid = channel.rule.outputDeviceUID {
            if let device = outputDevices.first(where: { $0.uid == uid }) { return device.name }
            return channel.rule.outputDeviceName ?? "Unavailable device"
        }
        return outputDevices.first(where: \.isSystemDefault).map { "System output · \($0.name)" }
            ?? "System output"
    }

    private static func friendlyName(for key: AppGroupKey) -> String {
        if key.isSystemSounds { return "System sounds" }
        if key.rawValue.hasPrefix("exec:") {
            return (key.rawValue.dropFirst(5) as NSString).lastPathComponent
        }
        if let url = bundleURL(for: key),
           let bundle = Bundle(url: url),
           let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) {
            return name
        }
        return key.rawValue.components(separatedBy: ".").last ?? key.rawValue
    }

    private static func bundleURL(for key: AppGroupKey) -> URL? {
        guard !key.rawValue.hasPrefix("exec:"), !key.rawValue.hasPrefix("pid:") else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: key.rawValue)
    }
}
