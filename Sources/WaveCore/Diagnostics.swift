import Foundation
import os

/// Wave's log. Deliberately small, deliberately in-memory, deliberately local.
///
/// Two rules shape this type:
///
/// * Nothing here may ever be called from the render thread. `os_log`, string
///   interpolation and `Date()` all allocate or take locks. The render thread
///   publishes counters through the lock-free cells in `WaveRTSupport` instead,
///   and the control thread turns those into log lines at its own pace.
/// * Nothing leaves the machine. The ring buffer exists so a person can read
///   what happened and copy it into a bug report themselves.
public final class Diagnostics: @unchecked Sendable {

    public static let subsystem = "app.wave.mixer"

    public enum Level: String, Sendable, Codable, CaseIterable {
        case debug, info, notice, warning, error

        var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .notice: return .default
            case .warning: return .default
            case .error: return .error
            }
        }
    }

    public struct Entry: Sendable, Identifiable, Equatable {
        public let id = UUID()
        public let date: Date
        public let level: Level
        public let category: String
        public let message: String

        public static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
    }

    public static let shared = Diagnostics()

    /// Kept small enough to stay cheap and large enough to cover a full
    /// plug/unplug/restart cycle.
    public let capacity: Int

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var loggers: [String: Logger] = [:]

    public init(capacity: Int = 500) {
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    public func log(_ level: Level, _ category: String, _ message: String) {
        let entry = Entry(date: Date(), level: level, category: category, message: message)

        lock.lock()
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        let logger = loggers[category] ?? {
            let created = Logger(subsystem: Self.subsystem, category: category)
            loggers[category] = created
            return created
        }()
        lock.unlock()

        logger.log(level: level.osLogType, "\(message, privacy: .public)")
    }

    public func debug(_ category: String, _ message: String) { log(.debug, category, message) }
    public func info(_ category: String, _ message: String) { log(.info, category, message) }
    public func notice(_ category: String, _ message: String) { log(.notice, category, message) }
    public func warning(_ category: String, _ message: String) { log(.warning, category, message) }
    public func error(_ category: String, _ message: String) { log(.error, category, message) }

    public var recent: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Plain-text dump a person can paste into an issue.
    public func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return recent
            .map { "\(formatter.string(from: $0.date)) [\($0.level.rawValue)] \($0.category): \($0.message)" }
            .joined(separator: "\n")
    }
}

/// Counters the render thread maintains and the control thread reads.
///
/// Every field is written from the audio callback, so they are all lock-free
/// cells; none of them is ever formatted or logged there.
public struct RenderStatisticsSnapshot: Equatable, Sendable {
    public var buffersRendered: UInt64 = 0
    public var framesRendered: UInt64 = 0
    /// Buffers the callback had to zero-fill because no input was available.
    public var underruns: UInt64 = 0
    /// Samples that hit the safety clamp.
    public var clampedSamples: UInt64 = 0
    /// Buffers where the tap delivered nothing but digital silence.
    public var silentBuffers: UInt64 = 0
    /// Buffers dropped because the plan and the actual buffer list disagreed.
    public var formatMismatches: UInt64 = 0

    public init() {}
}
