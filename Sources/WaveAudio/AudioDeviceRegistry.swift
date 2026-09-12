import Foundation
import CoreAudio
import AudioToolbox
import WaveCore

/// Tracks the output devices attached to this Mac and tells everyone when that
/// changes.
///
/// Three separate things can move under Wave's feet — the device list, the
/// default output, and any individual device's aliveness — and each has its own
/// HAL notification. The registry subscribes to all three, re-reads on any of
/// them and publishes one coalesced snapshot, so callers never have to reason
/// about which notification arrived.
public final class AudioDeviceRegistry: @unchecked Sendable {

    /// Aggregate devices Wave creates carry this prefix in their name so the
    /// registry can recognise and hide its own plumbing. They are also created
    /// private, which should keep them out of the device list entirely; the
    /// name check is a belt-and-braces guard for the case where a private
    /// aggregate is momentarily visible during teardown.
    public static let aggregateNamePrefix = "Wave Route"

    private let queue = DispatchQueue(label: "app.wave.device-registry")
    private let diagnostics: Diagnostics

    private var observers: [AudioPropertyObserver] = []
    private var perDeviceObservers: [AudioObjectID: [AudioPropertyObserver]] = [:]

    private var _devices: [OutputDeviceSnapshot] = []
    private var _defaultOutputUID: String?
    private let stateLock = NSLock()

    /// Called on the registry's queue whenever the snapshot changes.
    public var onChange: (([OutputDeviceSnapshot], String?) -> Void)?

    public init(diagnostics: Diagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    // MARK: - Snapshot

    public var devices: [OutputDeviceSnapshot] {
        stateLock.lock(); defer { stateLock.unlock() }
        return _devices
    }

    public var defaultOutputUID: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _defaultOutputUID
    }

    public func device(withUID uid: String) -> OutputDeviceSnapshot? {
        devices.first { $0.uid == uid }
    }

    // MARK: - Lifecycle

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.installSystemObservers()
            self.refreshLocked()
        }
    }

    public func stop() {
        queue.sync {
            observers.removeAll()
            perDeviceObservers.removeAll()
        }
    }

    deinit { stop() }

    private func installSystemObservers() {
        do {
            observers.append(try AudioPropertyObserver(objectID: .system,
                                                       selector: kAudioHardwarePropertyDevices,
                                                       queue: queue) { [weak self] in
                self?.diagnostics.info("Devices", "Device list changed")
                self?.refreshLocked()
            })
            observers.append(try AudioPropertyObserver(objectID: .system,
                                                       selector: kAudioHardwarePropertyDefaultOutputDevice,
                                                       queue: queue) { [weak self] in
                self?.diagnostics.info("Devices", "Default output device changed")
                self?.refreshLocked()
            })
        } catch {
            diagnostics.error("Devices", "Could not observe device changes: \(error)")
        }
    }

    /// Re-reads everything. Always runs on `queue`.
    private func refreshLocked() {
        dispatchPrecondition(condition: .onQueue(queue))

        let deviceIDs: [AudioObjectID]
        do {
            deviceIDs = try AudioObjectID.system.readArray(kAudioHardwarePropertyDevices,
                                                           filler: AudioObjectID.unknown)
        } catch {
            diagnostics.error("Devices", "Could not read device list: \(error)")
            return
        }

        let defaultID = (try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice,
                                                        defaultValue: AudioObjectID.unknown)) ?? .unknown
        let defaultUID = defaultID.isValid ? try? defaultID.readString(kAudioDevicePropertyDeviceUID) : nil

        var snapshots: [OutputDeviceSnapshot] = []
        var freshObservers: [AudioObjectID: [AudioPropertyObserver]] = [:]

        for deviceID in deviceIDs where deviceID.isValid {
            guard let snapshot = Self.snapshot(for: deviceID, defaultUID: defaultUID) else { continue }
            guard snapshot.outputChannelCount > 0 else { continue }
            guard !snapshot.name.hasPrefix(Self.aggregateNamePrefix) else { continue }
            snapshots.append(snapshot)

            // Re-use an existing per-device observer rather than churning
            // registrations on every list change.
            if let existing = perDeviceObservers[deviceID] {
                freshObservers[deviceID] = existing
            } else if let observer = try? AudioPropertyObserver(objectID: deviceID,
                                                                selector: kAudioDevicePropertyDeviceIsAlive,
                                                                queue: queue,
                                                                handler: { [weak self] in
                                                                    self?.refreshLocked()
                                                                }) {
                freshObservers[deviceID] = [observer]
            }
        }

        // Anything not carried over is dropped here, which removes its listener.
        perDeviceObservers = freshObservers

        snapshots.sort { lhs, rhs in
            if lhs.isSystemDefault != rhs.isSystemDefault { return lhs.isSystemDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        stateLock.lock()
        let changed = snapshots != _devices || defaultUID != _defaultOutputUID
        _devices = snapshots
        _defaultOutputUID = defaultUID
        stateLock.unlock()

        guard changed else { return }
        diagnostics.info("Devices",
                         "\(snapshots.count) output device(s); default = \(defaultUID ?? "none")")
        onChange?(snapshots, defaultUID)
    }

    // MARK: - Reading one device

    static func snapshot(for deviceID: AudioObjectID, defaultUID: String?) -> OutputDeviceSnapshot? {
        guard let uid = try? deviceID.readString(kAudioDevicePropertyDeviceUID), !uid.isEmpty else {
            return nil
        }
        let name = (try? deviceID.readString(kAudioObjectPropertyName))
            ?? (try? deviceID.readString(kAudioDevicePropertyDeviceNameCFString))
            ?? uid

        let channels = outputChannelCount(for: deviceID)
        let alive = (try? deviceID.readBool(kAudioDevicePropertyDeviceIsAlive)) ?? true
        let transport = transportType(for: deviceID)

        return OutputDeviceSnapshot(uid: uid,
                                    name: name,
                                    outputChannelCount: channels,
                                    isAlive: alive,
                                    transport: transport,
                                    isSystemDefault: uid == defaultUID)
    }

    /// Sums the channels across every output stream's buffer in the device's
    /// configuration. Reading `kAudioDevicePropertyStreamConfiguration` is the
    /// only reliable way to know whether a device can play anything: plenty of
    /// devices expose an output scope with zero channels.
    static func outputChannelCount(for deviceID: AudioObjectID) -> Int {
        var address = AudioObjectID.address(kAudioDevicePropertyStreamConfiguration,
                                            scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func transportType(for deviceID: AudioObjectID) -> OutputDeviceSnapshot.Transport {
        let raw: UInt32 = (try? deviceID.read(kAudioDevicePropertyTransportType, defaultValue: UInt32(0))) ?? 0
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeHDMI: return .hdmi
        case kAudioDeviceTransportTypeDisplayPort: return .displayPort
        case kAudioDeviceTransportTypeThunderbolt: return .thunderbolt
        case kAudioDeviceTransportTypeAggregate: return .aggregate
        case kAudioDeviceTransportTypeVirtual: return .virtual
        default: return .unknown
        }
    }

    /// Resolves a saved UID back to a live `AudioObjectID`.
    public static func deviceID(forUID uid: String) -> AudioObjectID? {
        guard let ids = try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices,
                                                            filler: AudioObjectID.unknown) else {
            return nil
        }
        for id in ids where id.isValid {
            if let candidate = try? id.readString(kAudioDevicePropertyDeviceUID), candidate == uid {
                return id
            }
        }
        return nil
    }
}
