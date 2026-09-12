import Foundation

/// A Core Audio output device, reduced to what Wave shows and decides on.
public struct OutputDeviceSnapshot: Equatable, Sendable, Identifiable {
    /// `kAudioDevicePropertyDeviceUID`. Stable across reboots and re-plugs for
    /// a given piece of hardware, which is why rules are keyed on it.
    public var uid: String
    public var name: String
    /// `kAudioObjectPropertyElementMain` output channel count. Zero means the
    /// device has no output side and Wave should not offer it.
    public var outputChannelCount: Int
    /// `kAudioDevicePropertyDeviceIsAlive`.
    public var isAlive: Bool
    /// `kAudioDevicePropertyTransportType`, mapped for iconography.
    public var transport: Transport
    /// True for the device Core Audio currently reports as the default output.
    public var isSystemDefault: Bool

    public var id: String { uid }

    public enum Transport: String, Equatable, Sendable, Codable {
        case builtIn, usb, bluetooth, airPlay, hdmi, displayPort, thunderbolt, aggregate, virtual, unknown
    }

    public init(uid: String,
                name: String,
                outputChannelCount: Int,
                isAlive: Bool = true,
                transport: Transport = .unknown,
                isSystemDefault: Bool = false) {
        self.uid = uid
        self.name = name
        self.outputChannelCount = outputChannelCount
        self.isAlive = isAlive
        self.transport = transport
        self.isSystemDefault = isSystemDefault
    }

    /// Whether Wave will offer this device as a destination.
    public var isUsableDestination: Bool { isAlive && outputChannelCount > 0 }
}

/// What happened when Wave tried to honour a rule's chosen device.
public enum DeviceResolution: Equatable, Sendable {
    /// The saved device is present and usable.
    case exact(OutputDeviceSnapshot)
    /// The rule asked to follow the system default, and here it is.
    case systemDefault(OutputDeviceSnapshot)
    /// The saved device is gone; Wave fell back to the current default and the
    /// UI must say so rather than pretending the rule is being honoured.
    case fellBack(to: OutputDeviceSnapshot, missingUID: String, missingName: String?)
    /// Nothing usable exists at all.
    case unavailable(missingUID: String?, missingName: String?)

    public var device: OutputDeviceSnapshot? {
        switch self {
        case .exact(let device), .systemDefault(let device), .fellBack(let device, _, _):
            return device
        case .unavailable:
            return nil
        }
    }

    /// True when Wave is not playing through the device the rule names.
    public var isDegraded: Bool {
        switch self {
        case .exact, .systemDefault: return false
        case .fellBack, .unavailable: return true
        }
    }
}

/// Chooses the device a rule should actually play through, given what is
/// plugged in right now.
///
/// Pulled out as a pure function because the interesting behaviour — what
/// happens the moment somebody yanks their AirPods out — is exactly the
/// behaviour that is painful to reproduce by hand.
public enum DeviceFallbackPolicy {

    public static func resolve(rule: RoutingRule,
                               devices: [OutputDeviceSnapshot],
                               systemDefaultUID: String?) -> DeviceResolution {
        let usable = devices.filter(\.isUsableDestination)
        let systemDefault = usable.first { $0.uid == systemDefaultUID }
            ?? usable.first { $0.isSystemDefault }

        guard let requestedUID = rule.outputDeviceUID else {
            // The rule follows the system default by design.
            if let systemDefault { return .systemDefault(systemDefault) }
            return .unavailable(missingUID: nil, missingName: nil)
        }

        if let exact = usable.first(where: { $0.uid == requestedUID }) {
            return .exact(exact)
        }

        // The named device is not available. Falling back to the current
        // default keeps audio audible; the rule itself is deliberately left
        // untouched on disk so the original choice is restored the moment the
        // device comes back.
        if let systemDefault {
            return .fellBack(to: systemDefault,
                             missingUID: requestedUID,
                             missingName: rule.outputDeviceName)
        }

        return .unavailable(missingUID: requestedUID, missingName: rule.outputDeviceName)
    }

    /// Given a device list that has just changed, reports which of the supplied
    /// rules now resolve differently. The engine uses this to restart only the
    /// routes that actually need it instead of tearing everything down on every
    /// hot-plug notification.
    public static func rulesNeedingRerouting(rules: [RoutingRule],
                                             previous: [OutputDeviceSnapshot],
                                             current: [OutputDeviceSnapshot],
                                             previousDefaultUID: String?,
                                             currentDefaultUID: String?) -> [AppGroupKey] {
        rules.compactMap { rule in
            let before = resolve(rule: rule, devices: previous, systemDefaultUID: previousDefaultUID)
            let after = resolve(rule: rule, devices: current, systemDefaultUID: currentDefaultUID)
            return before.device?.uid == after.device?.uid ? nil : rule.appKey
        }
    }
}
