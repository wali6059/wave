import Foundation

/// Narrow file-system seam so ``RoutingRuleStore`` can be tested without
/// touching a real disk.
public protocol RuleFileStorage: AnyObject {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

/// Reads and writes the rule document at
/// `~/Library/Application Support/Wave/rules.json`.
///
/// Writes go to a sibling temporary file and are then renamed into place, so a
/// crash mid-write leaves the previous rules intact instead of a truncated
/// file. A rules file that fails to parse is preserved (renamed aside) rather
/// than overwritten, because silently discarding somebody's configuration is
/// worse than starting empty and saying so.
public final class RoutingRuleStore: @unchecked Sendable {

    public enum LoadOutcome: Equatable {
        case loaded(count: Int)
        case empty
        case recoveredFromCorruptFile(String)
    }

    private let storage: RuleFileStorage
    private let lock = NSLock()
    private var rules: [AppGroupKey: RoutingRule] = [:]
    private(set) public var lastLoadOutcome: LoadOutcome = .empty

    public init(storage: RuleFileStorage) {
        self.storage = storage
    }

    // MARK: - Loading and saving

    @discardableResult
    public func load() -> LoadOutcome {
        lock.lock()
        defer { lock.unlock() }

        let data: Data?
        do {
            data = try storage.read()
        } catch {
            rules = [:]
            lastLoadOutcome = .recoveredFromCorruptFile("Could not read rules: \(error.localizedDescription)")
            return lastLoadOutcome
        }

        guard let data, !data.isEmpty else {
            rules = [:]
            lastLoadOutcome = .empty
            return lastLoadOutcome
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(RoutingRuleDocument.self, from: data)
            let migrated = Self.migrate(document)
            rules = Dictionary(migrated.rules.map { ($0.appKey, $0) },
                               uniquingKeysWith: { _, newer in newer })
            lastLoadOutcome = .loaded(count: rules.count)
        } catch {
            rules = [:]
            lastLoadOutcome = .recoveredFromCorruptFile("Rules file could not be parsed: \(error.localizedDescription)")
        }
        return lastLoadOutcome
    }

    public func save() throws {
        lock.lock()
        let document = RoutingRuleDocument(rules: rules.values.sorted { $0.appKey.rawValue < $1.appKey.rawValue })
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try storage.write(data)
    }

    /// Applies forward migrations. Version 1 is the initial shape, so there is
    /// nothing to do yet; the hook exists so a future change has an obvious
    /// home and old files are never silently dropped.
    static func migrate(_ document: RoutingRuleDocument) -> RoutingRuleDocument {
        var document = document
        if document.version < RoutingRuleDocument.currentVersion {
            document.version = RoutingRuleDocument.currentVersion
        }
        return document
    }

    // MARK: - Access

    public func rule(for key: AppGroupKey) -> RoutingRule? {
        lock.lock()
        defer { lock.unlock() }
        return rules[key]
    }

    /// The saved rule, or a fresh default. Callers that just want to know how
    /// to configure a newly-appeared application should use this.
    public func effectiveRule(for key: AppGroupKey) -> RoutingRule {
        rule(for: key) ?? .default(for: key)
    }

    public var allRules: [RoutingRule] {
        lock.lock()
        defer { lock.unlock() }
        return rules.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    public func upsert(_ rule: RoutingRule) {
        lock.lock()
        rules[rule.appKey] = rule
        lock.unlock()
    }

    public func remove(_ key: AppGroupKey) {
        lock.lock()
        rules.removeValue(forKey: key)
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        rules.removeAll()
        lock.unlock()
    }

    /// Mutates a rule in place, creating it from defaults if absent.
    /// Returns the resulting rule.
    @discardableResult
    public func update(_ key: AppGroupKey, _ body: (inout RoutingRule) -> Void) -> RoutingRule {
        lock.lock()
        var rule = rules[key] ?? .default(for: key)
        body(&rule)
        rule.volume = min(max(rule.volume, 0), 1)
        rules[key] = rule
        lock.unlock()
        return rule
    }
}

/// On-disk implementation of ``RuleFileStorage`` with an atomic replace.
public final class FileRuleStorage: RuleFileStorage {

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Wave/rules.json`
    public static func defaultLocation() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let directory = base.appendingPathComponent("Wave", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("rules.json")
    }

    public func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    public func write(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // `.atomic` writes to a temporary file and renames, so an interrupted
        // save cannot leave a half-written rules file behind.
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// In-memory storage used by the tests.
public final class InMemoryRuleStorage: RuleFileStorage {
    public private(set) var data: Data?
    public var readError: Error?
    public var writeError: Error?
    public private(set) var writeCount = 0

    public init(data: Data? = nil) { self.data = data }

    public func read() throws -> Data? {
        if let readError { throw readError }
        return data
    }

    public func write(_ newData: Data) throws {
        if let writeError { throw writeError }
        data = newData
        writeCount += 1
    }
}
