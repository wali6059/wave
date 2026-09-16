import Foundation
import CoreAudio
import AudioToolbox
import AppKit
import Darwin
import WaveCore

/// One application as the mixer presents it: a friendly name, an icon, and the
/// set of Core Audio process objects whose audio belongs to it.
public struct DiscoveredApp: Equatable, Sendable, Identifiable {

    /// What kind of thing this row represents.
    ///
    /// macOS registers a dozen or more background daemons as audio processes —
    /// `corespeechd`, `universalaccessd`, `systemstats` and friends. Listing
    /// them beside Spotify buries the two rows anyone actually came for, so the
    /// mixer sorts and sections by this.
    public enum Kind: Int, Equatable, Sendable, Comparable {
        /// Something with a Dock icon and a bundle: Spotify, Chrome, FaceTime.
        case application = 0
        /// The aggregate of system and interface sounds.
        case systemSounds = 1
        /// A daemon or bare executable. Real, occasionally useful, rarely what
        /// you are looking for.
        case backgroundProcess = 2

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var kind: Kind
    public var key: AppGroupKey
    public var displayName: String
    public var bundleIdentifier: String?
    public var bundleURL: URL?
    /// Every Core Audio process object that belongs to this application,
    /// including its helpers. A tap is created over the whole set at once.
    public var processObjectIDs: [AudioObjectID]
    public var pids: [Int32]
    /// True when at least one member process is currently producing output.
    public var isProducingOutput: Bool
    public var isSystemSounds: Bool

    public var id: String { key.rawValue }
}

/// Finds the applications currently able to play audio and keeps that list
/// fresh.
///
/// The HAL exposes an audio process object per process, not per application, so
/// the interesting work here is turning `com.google.Chrome.helper` and four
/// anonymous renderer PIDs into a single row that says "Google Chrome" and can
/// be tapped as a unit.
public final class AudioProcessDiscovery: @unchecked Sendable {

    private let queue = DispatchQueue(label: "app.wave.process-discovery")
    private let diagnostics: Diagnostics
    private var propertyObservers: [AudioPropertyObserver] = []
    private var runningObservers: [AudioObjectID: AudioPropertyObserver] = [:]

    private let stateLock = NSLock()
    private var _apps: [DiscoveredApp] = []

    /// PID of this process. Never tapped: tapping ourselves would feed our own
    /// render output straight back into a tap and build a feedback loop.
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Observers called on the discovery queue when the application list
    /// changes. A list, not a single slot, so the routing engine and the view
    /// model cannot disconnect each other by both subscribing.
    private var observers: [([DiscoveredApp]) -> Void] = []

    /// Registers an observer and immediately delivers the current list.
    public func addObserver(_ handler: @escaping ([DiscoveredApp]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.observers.append(handler)
            handler(self.apps)
        }
    }

    public init(diagnostics: Diagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    public var apps: [DiscoveredApp] {
        stateLock.lock(); defer { stateLock.unlock() }
        return _apps
    }

    public func app(for key: AppGroupKey) -> DiscoveredApp? {
        apps.first { $0.key == key }
    }

    // MARK: - Lifecycle

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                self.propertyObservers.append(try AudioPropertyObserver(objectID: .system,
                                                                selector: kAudioHardwarePropertyProcessObjectList,
                                                                queue: self.queue) { [weak self] in
                    self?.refresh()
                })
            } catch {
                self.diagnostics.error("Processes", "Could not observe the process list: \(error)")
            }
            self.refresh()
        }
    }

    public func stop() {
        queue.sync {
            propertyObservers.removeAll()
            runningObservers.removeAll()
            observers.removeAll()
        }
    }

    deinit { stop() }

    /// Forces a re-read. Cheap enough to call from a timer as a safety net for
    /// the notifications Core Audio does not always send (a process that starts
    /// playing does not necessarily change the *list*).
    public func refreshNow() {
        queue.async { [weak self] in self?.refresh() }
    }

    // MARK: - Discovery

    private func refresh() {
        dispatchPrecondition(condition: .onQueue(queue))

        let processObjects: [AudioObjectID]
        do {
            processObjects = try AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList,
                                                                filler: AudioObjectID.unknown)
        } catch {
            diagnostics.error("Processes", "Could not read the process list: \(error)")
            return
        }

        let runningApplications = NSWorkspace.shared.runningApplications
        var applicationsByPID: [Int32: NSRunningApplication] = [:]
        for application in runningApplications {
            applicationsByPID[application.processIdentifier] = application
        }

        var facts: [AudioProcessFacts] = []
        var objectIDByPID: [Int32: AudioObjectID] = [:]
        var freshRunningObservers: [AudioObjectID: AudioPropertyObserver] = [:]

        for objectID in processObjects where objectID.isValid {
            guard let pid: pid_t = try? objectID.read(kAudioProcessPropertyPID, defaultValue: pid_t(-1)),
                  pid > 0 else { continue }

            // Never tap ourselves.
            guard pid != ownPID else { continue }

            let bundleID = (try? objectID.readString(kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 }
            let executablePath = Self.executablePath(for: pid)
            let isRunningOutput = (try? objectID.readBool(kAudioProcessPropertyIsRunningOutput)) ?? false

            var enclosingBundleID: String?
            var enclosingBundleName: String?
            if let application = applicationsByPID[pid] {
                enclosingBundleID = application.bundleIdentifier
                enclosingBundleName = application.localizedName
            } else if let executablePath,
                      let appPath = ProcessGrouping.outermostAppBundlePath(forExecutablePath: executablePath),
                      let bundle = Bundle(path: appPath) {
                enclosingBundleID = bundle.bundleIdentifier
                enclosingBundleName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            }

            facts.append(AudioProcessFacts(pid: pid,
                                           bundleID: bundleID,
                                           executablePath: executablePath,
                                           enclosingBundleID: enclosingBundleID,
                                           enclosingBundleName: enclosingBundleName,
                                           isProducingOutput: isRunningOutput))
            objectIDByPID[pid] = objectID

            if let existing = runningObservers[objectID] {
                freshRunningObservers[objectID] = existing
            } else if let observer = try? AudioPropertyObserver(objectID: objectID,
                                                                selector: kAudioProcessPropertyIsRunningOutput,
                                                                queue: queue,
                                                                handler: { [weak self] in
                                                                    self?.refresh()
                                                                }) {
                freshRunningObservers[objectID] = observer
            }
        }

        runningObservers = freshRunningObservers

        let grouped = ProcessGrouping.group(facts)
        var apps: [DiscoveredApp] = []

        for (key, members) in grouped {
            let pids = members.map(\.pid)
            let objectIDs = pids.compactMap { objectIDByPID[$0] }
            guard !objectIDs.isEmpty else { continue }

            let (name, bundleURL, bundleIdentifier) = Self.presentation(for: key,
                                                                        members: members,
                                                                        applicationsByPID: applicationsByPID)

            let kind: DiscoveredApp.Kind
            if key.isSystemSounds {
                kind = .systemSounds
            } else if members.contains(where: { applicationsByPID[$0.pid] != nil })
                        || bundleURL?.pathExtension == "app" {
                // Either macOS considers it a running application, or it lives
                // in an .app wrapper. Both mean a person would call it an app.
                kind = .application
            } else {
                kind = .backgroundProcess
            }

            apps.append(DiscoveredApp(kind: kind,
                                      key: key,
                                      displayName: name,
                                      bundleIdentifier: bundleIdentifier,
                                      bundleURL: bundleURL,
                                      processObjectIDs: objectIDs,
                                      pids: pids,
                                      isProducingOutput: members.contains(where: \.isProducingOutput),
                                      isSystemSounds: key.isSystemSounds))
        }

        // Applications first, then system sounds, then daemons; within each
        // band, whatever is making noise floats to the top.
        apps.sort { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            if lhs.isProducingOutput != rhs.isProducingOutput { return lhs.isProducingOutput }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }

        stateLock.lock()
        let changed = apps != _apps
        _apps = apps
        stateLock.unlock()

        guard changed else { return }
        for observer in observers { observer(apps) }
    }

    // MARK: - Naming

    static func presentation(for key: AppGroupKey,
                             members: [AudioProcessFacts],
                             applicationsByPID: [Int32: NSRunningApplication]) -> (name: String, bundleURL: URL?, bundleIdentifier: String?) {
        if key.isSystemSounds {
            return ("System sounds", nil, nil)
        }

        // Prefer a member that macOS itself considers an application: that is
        // the one with the name and icon the user knows.
        for member in members {
            if let application = applicationsByPID[member.pid],
               let name = application.localizedName {
                return (name, application.bundleURL, application.bundleIdentifier)
            }
        }

        for member in members {
            if let name = member.enclosingBundleName {
                let url = member.executablePath
                    .flatMap { ProcessGrouping.outermostAppBundlePath(forExecutablePath: $0) }
                    .map { URL(fileURLWithPath: $0) }
                return (name, url, member.enclosingBundleID)
            }
        }

        // The group key may name an application none of the member processes
        // belong to — a daemon remapped to the app it serves, like
        // avconferenced to FaceTime. Ask the system where that application
        // lives so the row gets the name and icon a person recognises instead
        // of the daemon's.
        if !key.rawValue.hasPrefix("exec:"), !key.rawValue.hasPrefix("pid:"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key.rawValue) {
            let name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return (name, url, key.rawValue)
        }

        // Last resort: the executable's own name. Better than an opaque bundle
        // identifier and much better than a PID.
        if let path = members.first?.executablePath {
            return ((path as NSString).lastPathComponent, URL(fileURLWithPath: path), members.first?.bundleID)
        }

        return (key.rawValue, nil, members.first?.bundleID)
    }

    static func executablePath(for pid: pid_t) -> String? {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
        defer { buffer.deallocate() }
        let length = proc_pidpath(pid, buffer, UInt32(MAXPATHLEN))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
