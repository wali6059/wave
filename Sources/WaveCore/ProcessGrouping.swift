import Foundation

/// The facts Wave can learn about one Core Audio process object without
/// touching AppKit. Kept free of platform types so the grouping rules below
/// are testable in isolation.
public struct AudioProcessFacts: Equatable, Sendable {
    public var pid: Int32
    /// `kAudioProcessPropertyBundleID`. Frequently the helper's own identifier
    /// (`com.google.Chrome.helper`) rather than the app the user recognises.
    public var bundleID: String?
    /// Absolute path of the running executable, from `proc_pidpath`.
    public var executablePath: String?
    /// Bundle identifier of the enclosing application bundle, when the
    /// executable path sits inside one.
    public var enclosingBundleID: String?
    /// Localised name of the enclosing application, when one is known.
    public var enclosingBundleName: String?
    public var isProducingOutput: Bool

    public init(pid: Int32,
                bundleID: String? = nil,
                executablePath: String? = nil,
                enclosingBundleID: String? = nil,
                enclosingBundleName: String? = nil,
                isProducingOutput: Bool = false) {
        self.pid = pid
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.enclosingBundleID = enclosingBundleID
        self.enclosingBundleName = enclosingBundleName
        self.isProducingOutput = isProducingOutput
    }
}

/// Stable identity Wave persists rules against.
///
/// Never a PID: PIDs are recycled within a session and meaningless across
/// launches. A bundle identifier survives relaunch, update and reboot, which
/// is what makes "Spotify is always at 65% on the studio speakers" work.
public struct AppGroupKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// Fallback identity for a process with no discoverable bundle, keyed on
    /// the executable path so at least it is stable for the life of the
    /// install.
    public static func executable(_ path: String) -> AppGroupKey {
        AppGroupKey("exec:" + path)
    }

    /// Identity used for the aggregate of system-owned sounds.
    public static let systemSounds = AppGroupKey("com.apple.systemsounds")

    public var isSystemSounds: Bool { self == .systemSounds }

    public var description: String { rawValue }
}

/// Folds the helper processes that modern applications spawn back into the one
/// entry a person expects to see.
///
/// Chrome renders each tab in `Google Chrome Helper (Renderer)`, Electron apps
/// route audio through `<App> Helper`, and Safari plays through
/// `com.apple.WebKit.GPU`. Presenting those raw would give a mixer full of
/// anonymous rows that appear and disappear as tabs open. Grouping means one
/// row per application and, because a tap can name several process objects at
/// once, one tap that covers all of that application's helpers.
public enum ProcessGrouping {

    /// Bundle identifiers whose audio is produced on behalf of another app, and
    /// the app it should be attributed to.
    ///
    /// Safari's content and GPU processes are the awkward case: the WebKit GPU
    /// process also serves `WKWebView`s hosted by other applications, so
    /// attributing it to Safari is a best-effort guess. It is the right guess
    /// the overwhelming majority of the time, and it is documented as a known
    /// limitation rather than hidden.
    public static let explicitOwners: [String: String] = [
        "com.apple.WebKit.GPU": "com.apple.Safari",
        "com.apple.WebKit.WebContent": "com.apple.Safari",
        "com.apple.WebKit.Networking": "com.apple.Safari",

        // FaceTime does not play its call audio itself: it goes through
        // avconferenced, Apple's AV conferencing daemon, with callservicesd
        // handling call setup. Left ungrouped, a FaceTime call shows up in the
        // mixer as a row named "avconferenced", which is useless to anyone
        // trying to turn the person they are talking to down.
        //
        // Same best-effort caveat as WebKit above: avconferenced also carries
        // calls relayed from an iPhone, so "FaceTime" is the right label the
        // overwhelming majority of the time rather than always.
        "com.apple.avconferenced": "com.apple.FaceTime",
        "com.apple.TelephonyUtilities": "com.apple.FaceTime",
    ]

    /// Names for group keys that no member process can supply, because the
    /// owning application is not the one making the sound.
    ///
    /// A LaunchServices lookup normally finds the app and its icon, but it can
    /// miss, and falling through to the daemon's executable name puts
    /// "avconferenced" in the mixer where a person expects "FaceTime".
    public static let friendlyNames: [String: String] = [
        "com.apple.FaceTime": "FaceTime",
        "com.apple.Safari": "Safari",
    ]

    /// Suffixes that mark a bundle identifier as belonging to a helper.
    /// Ordered longest-first so `.helper.renderer` is stripped before
    /// `.helper`.
    public static let helperSuffixes: [String] = [
        ".helper.renderer",
        ".helper.plugin",
        ".helper.gpu",
        ".helper.alerts",
        ".framework.helper",
        ".helper",
    ]

    /// Process names that Core Audio attributes system and UI sounds to.
    public static let systemSoundExecutables: Set<String> = [
        "coreaudiod",
        "SystemUIServer",
    ]

    /// Resolves the application a process's audio should be filed under.
    public static func groupKey(for facts: AudioProcessFacts) -> AppGroupKey {
        if let executablePath = facts.executablePath {
            let name = (executablePath as NSString).lastPathComponent
            if systemSoundExecutables.contains(name) {
                return .systemSounds
            }
        }

        // A bundle identifier taken from the enclosing .app wrapper is the most
        // trustworthy signal: it is what the user sees in the Dock. Prefer it
        // over the helper's own identifier.
        if let enclosing = facts.enclosingBundleID, !enclosing.isEmpty {
            return AppGroupKey(canonicalise(enclosing))
        }

        if let bundleID = facts.bundleID, !bundleID.isEmpty {
            return AppGroupKey(canonicalise(bundleID))
        }

        if let executablePath = facts.executablePath, !executablePath.isEmpty {
            return .executable(executablePath)
        }

        return AppGroupKey("pid:\(facts.pid)")
    }

    /// Reduces a helper's bundle identifier to its owning application's.
    public static func canonicalise(_ bundleID: String) -> String {
        let lowered = bundleID.lowercased()

        if let owner = explicitOwners[bundleID] { return owner }
        if let match = explicitOwners.first(where: { $0.key.lowercased() == lowered }) {
            return match.value
        }

        for suffix in helperSuffixes where lowered.hasSuffix(suffix) {
            let trimmed = String(bundleID.dropLast(suffix.count))
            if !trimmed.isEmpty { return trimmed }
        }

        return bundleID
    }

    /// Walks an executable path outwards to the outermost `.app` wrapper.
    ///
    /// Electron nests helpers inside the host app
    /// (`/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/...`), so
    /// the *outermost* wrapper is the one the user recognises. Returns `nil`
    /// for executables that live outside any bundle.
    public static func outermostAppBundlePath(forExecutablePath path: String) -> String? {
        let components = path.components(separatedBy: "/")
        var rebuilt = ""
        for component in components {
            if component.isEmpty { continue }
            rebuilt += "/" + component
            if component.hasSuffix(".app") {
                return rebuilt
            }
        }
        return nil
    }

    /// Groups a flat list of audio process facts into one bucket per
    /// application, preserving discovery order so the UI does not reshuffle.
    public static func group(_ processes: [AudioProcessFacts]) -> [(key: AppGroupKey, members: [AudioProcessFacts])] {
        var order: [AppGroupKey] = []
        var buckets: [AppGroupKey: [AudioProcessFacts]] = [:]

        for process in processes {
            let key = groupKey(for: process)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(process)
        }

        return order.map { (key: $0, members: buckets[$0] ?? []) }
    }
}
