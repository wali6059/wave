import Foundation
import CoreAudio
import AudioToolbox
import WaveCore

/// Reads and writes the hardware volume of the current default output device.
///
/// This one control genuinely *is* global, and Wave labels it as such. It is
/// included because a mixer without a master fader is annoying to use, not
/// because it substitutes for per-app control — every other fader in Wave goes
/// through the tap pipeline and touches nothing system-wide.
///
/// Not every device exposes a settable volume: aggregate devices, most HDMI and
/// DisplayPort outputs and some USB interfaces have no software volume at all.
/// ``isAvailable`` reports that honestly so the UI can disable the control
/// rather than move a fader that does nothing.
public final class MasterOutputController: @unchecked Sendable {

    private let diagnostics: Diagnostics
    private let queue = DispatchQueue(label: "app.wave.master-output")
    private var observers: [AudioPropertyObserver] = []

    public var onChange: (() -> Void)?

    public init(diagnostics: Diagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                self.observers.append(try AudioPropertyObserver(objectID: .system,
                                                                selector: kAudioHardwarePropertyDefaultOutputDevice,
                                                                queue: self.queue) { [weak self] in
                    self?.rebindDeviceObservers()
                    self?.onChange?()
                })
            } catch {
                self.diagnostics.warning("Master", "Could not observe the default output device: \(error)")
            }
            self.rebindDeviceObservers()
        }
    }

    public func stop() {
        queue.sync { observers.removeAll() }
    }

    deinit { stop() }

    private func rebindDeviceObservers() {
        // Keep the system-level observer (index 0) and replace any per-device
        // ones, so switching the default output does not accumulate listeners.
        if observers.count > 1 { observers.removeSubrange(1...) }
        guard let deviceID = Self.defaultOutputDeviceID else { return }
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            if let observer = try? AudioPropertyObserver(objectID: deviceID,
                                                         selector: selector,
                                                         scope: kAudioObjectPropertyScopeOutput,
                                                         queue: queue,
                                                         handler: { [weak self] in self?.onChange?() }) {
                observers.append(observer)
            }
        }
    }

    static var defaultOutputDeviceID: AudioObjectID? {
        guard let id = try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice,
                                                      defaultValue: AudioObjectID.unknown),
              id.isValid else { return nil }
        return id
    }

    /// Whether the current default output exposes a software volume control.
    public var isAvailable: Bool {
        guard let deviceID = Self.defaultOutputDeviceID else { return false }
        return deviceID.hasProperty(kAudioDevicePropertyVolumeScalar,
                                    scope: kAudioObjectPropertyScopeOutput)
    }

    /// Current master volume in `0...1`, or `nil` when the device has none.
    public var volume: Float? {
        get {
            guard let deviceID = Self.defaultOutputDeviceID else { return nil }
            return try? deviceID.read(kAudioDevicePropertyVolumeScalar,
                                      scope: kAudioObjectPropertyScopeOutput,
                                      defaultValue: Float(0))
        }
        set {
            guard let newValue, let deviceID = Self.defaultOutputDeviceID else { return }
            let clamped = min(max(newValue, 0), 1)
            do {
                try deviceID.write(kAudioDevicePropertyVolumeScalar,
                                   scope: kAudioObjectPropertyScopeOutput,
                                   value: clamped)
            } catch {
                diagnostics.warning("Master", "Could not set master volume: \(error)")
            }
        }
    }

    public var isMuted: Bool {
        get {
            guard let deviceID = Self.defaultOutputDeviceID else { return false }
            return (try? deviceID.readBool(kAudioDevicePropertyMute,
                                           scope: kAudioObjectPropertyScopeOutput)) ?? false
        }
        set {
            guard let deviceID = Self.defaultOutputDeviceID else { return }
            do {
                try deviceID.write(kAudioDevicePropertyMute,
                                   scope: kAudioObjectPropertyScopeOutput,
                                   value: UInt32(newValue ? 1 : 0))
            } catch {
                diagnostics.warning("Master", "Could not set master mute: \(error)")
            }
        }
    }

    public var supportsMute: Bool {
        guard let deviceID = Self.defaultOutputDeviceID else { return false }
        return deviceID.hasProperty(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
    }

    public var deviceName: String? {
        guard let deviceID = Self.defaultOutputDeviceID else { return nil }
        return try? deviceID.readString(kAudioObjectPropertyName)
    }
}
