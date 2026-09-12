import Foundation

/// A saved instruction: "when this application plays, put it here, at this
/// level".
///
/// Persisted against ``AppGroupKey`` (a bundle identifier) and an output device
/// UID. Neither is a PID and neither is an `AudioObjectID`; both of those are
/// assigned fresh on every launch and every hot-plug, so a rule keyed on them
/// would silently stop matching.
public struct RoutingRule: Equatable, Sendable, Codable {

    public var appKey: AppGroupKey
    /// Fader travel in `0...1`.
    public var volume: Float
    public var isMuted: Bool
    /// `kAudioDevicePropertyDeviceUID` of the chosen destination, or `nil` to
    /// mean "follow the system default output".
    public var outputDeviceUID: String?
    /// Human-readable name captured when the rule was written, so Wave can say
    /// *which* device is missing when it has gone away.
    public var outputDeviceName: String?
    /// Last time Wave saw this application produce audio. Used only to order
    /// the "recently active" section.
    public var lastSeen: Date

    public init(appKey: AppGroupKey,
                volume: Float = 1.0,
                isMuted: Bool = false,
                outputDeviceUID: String? = nil,
                outputDeviceName: String? = nil,
                lastSeen: Date = Date()) {
        self.appKey = appKey
        self.volume = min(max(volume, 0), 1)
        self.isMuted = isMuted
        self.outputDeviceUID = outputDeviceUID
        self.outputDeviceName = outputDeviceName
        self.lastSeen = lastSeen
    }

    /// A rule that only sets volume/mute and lets the system pick the device
    /// does not need Wave to intercept anything, so routing stays off and the
    /// application keeps its normal, untouched path to the speakers.
    public var requiresRouting: Bool {
        outputDeviceUID != nil || isMuted || volume < 1.0
    }

    /// Defaults for an application Wave has never seen.
    public static func `default`(for appKey: AppGroupKey) -> RoutingRule {
        RoutingRule(appKey: appKey, volume: 1.0, isMuted: false, outputDeviceUID: nil)
    }
}

/// Everything Wave persists between launches.
public struct RoutingRuleDocument: Equatable, Sendable, Codable {
    /// Bumped whenever the on-disk shape changes so old files can be migrated
    /// rather than discarded.
    public static let currentVersion = 1

    public var version: Int
    public var rules: [RoutingRule]

    public init(version: Int = RoutingRuleDocument.currentVersion, rules: [RoutingRule] = []) {
        self.version = version
        self.rules = rules
    }
}
