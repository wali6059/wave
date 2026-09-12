import XCTest
@testable import WaveCore

final class RoutingRuleTests: XCTestCase {

    func testDefaultRuleNeedsNoRouting() {
        // The important consequence: an app the user has not touched keeps its
        // untouched system audio path, and Wave never inserts itself.
        XCTAssertFalse(RoutingRule.default(for: AppGroupKey("com.example.app")).requiresRouting)
    }

    func testRoutingRequiredWhenAnythingIsSet() {
        var rule = RoutingRule.default(for: AppGroupKey("com.example.app"))
        rule.volume = 0.5
        XCTAssertTrue(rule.requiresRouting)

        rule = RoutingRule.default(for: AppGroupKey("com.example.app"))
        rule.isMuted = true
        XCTAssertTrue(rule.requiresRouting)

        rule = RoutingRule.default(for: AppGroupKey("com.example.app"))
        rule.outputDeviceUID = "device-uid"
        XCTAssertTrue(rule.requiresRouting)
    }

    func testVolumeIsClampedOnInit() {
        XCTAssertEqual(RoutingRule(appKey: AppGroupKey("a"), volume: 5).volume, 1)
        XCTAssertEqual(RoutingRule(appKey: AppGroupKey("a"), volume: -5).volume, 0)
    }
}

final class RoutingRuleStoreTests: XCTestCase {

    private var storage: InMemoryRuleStorage!
    private var store: RoutingRuleStore!

    override func setUp() {
        super.setUp()
        storage = InMemoryRuleStorage()
        store = RoutingRuleStore(storage: storage)
    }

    func testLoadingNothingIsEmptyNotAnError() {
        XCTAssertEqual(store.load(), .empty)
        XCTAssertTrue(store.allRules.isEmpty)
    }

    func testRoundTripsThroughDisk() throws {
        let key = AppGroupKey("com.spotify.client")
        store.upsert(RoutingRule(appKey: key,
                                 volume: 0.65,
                                 isMuted: false,
                                 outputDeviceUID: "studio-uid",
                                 outputDeviceName: "Studio speakers"))
        try store.save()

        let reloaded = RoutingRuleStore(storage: storage)
        XCTAssertEqual(reloaded.load(), .loaded(count: 1))

        let rule = try XCTUnwrap(reloaded.rule(for: key))
        XCTAssertEqual(rule.volume, 0.65, accuracy: 1e-6)
        XCTAssertEqual(rule.outputDeviceUID, "studio-uid")
        XCTAssertEqual(rule.outputDeviceName, "Studio speakers")
        XCTAssertFalse(rule.isMuted)
    }

    /// Rules are keyed on bundle identifier, never on PID, so they survive the
    /// application quitting and relaunching with a completely different PID.
    func testRulesAreKeyedByBundleIdentifierNotPID() throws {
        let key = AppGroupKey("com.google.Chrome")
        store.upsert(RoutingRule(appKey: key, volume: 0.3, outputDeviceUID: "macbook"))
        try store.save()

        // Simulate a relaunch: brand new store, brand new process, same key.
        let afterRelaunch = RoutingRuleStore(storage: storage)
        afterRelaunch.load()
        XCTAssertEqual(afterRelaunch.effectiveRule(for: key).volume, 0.3, accuracy: 1e-6)
        XCTAssertEqual(afterRelaunch.effectiveRule(for: key).outputDeviceUID, "macbook")
    }

    func testUnknownKeyGetsDefaults() {
        let rule = store.effectiveRule(for: AppGroupKey("com.unknown.app"))
        XCTAssertEqual(rule.volume, 1)
        XCTAssertFalse(rule.isMuted)
        XCTAssertNil(rule.outputDeviceUID)
    }

    func testUpdateCreatesThenMutates() {
        let key = AppGroupKey("com.example.app")
        var result = store.update(key) { $0.volume = 0.4 }
        XCTAssertEqual(result.volume, 0.4, accuracy: 1e-6)

        result = store.update(key) { $0.isMuted = true }
        XCTAssertEqual(result.volume, 0.4, accuracy: 1e-6, "existing fields must survive a partial update")
        XCTAssertTrue(result.isMuted)
    }

    func testUpdateClampsVolume() {
        let result = store.update(AppGroupKey("a")) { $0.volume = 9 }
        XCTAssertEqual(result.volume, 1)
    }

    func testRemove() throws {
        let key = AppGroupKey("com.example.app")
        store.upsert(RoutingRule(appKey: key, volume: 0.5))
        store.remove(key)
        XCTAssertNil(store.rule(for: key))
    }

    /// A rules file that cannot be parsed must not be silently replaced with an
    /// empty one, and must not take the app down either.
    func testCorruptFileIsReportedNotSwallowed() {
        storage = InMemoryRuleStorage(data: Data("{ this is not json".utf8))
        store = RoutingRuleStore(storage: storage)

        let outcome = store.load()
        guard case .recoveredFromCorruptFile = outcome else {
            return XCTFail("expected a corrupt-file outcome, got \(outcome)")
        }
        XCTAssertTrue(store.allRules.isEmpty)
    }

    func testReadErrorIsReported() {
        struct Boom: Error {}
        storage.readError = Boom()
        guard case .recoveredFromCorruptFile = store.load() else {
            return XCTFail("expected a recovery outcome")
        }
    }

    func testSavePropagatesWriteErrors() {
        struct Boom: Error {}
        storage.writeError = Boom()
        store.upsert(RoutingRule(appKey: AppGroupKey("a")))
        XCTAssertThrowsError(try store.save())
    }

    func testSavedDocumentCarriesAVersion() throws {
        store.upsert(RoutingRule(appKey: AppGroupKey("a")))
        try store.save()
        let data = try XCTUnwrap(storage.data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(RoutingRuleDocument.self, from: data)
        XCTAssertEqual(document.version, RoutingRuleDocument.currentVersion)
    }

    func testMigrationRaisesOldVersions() {
        let old = RoutingRuleDocument(version: 0, rules: [RoutingRule(appKey: AppGroupKey("a"))])
        let migrated = RoutingRuleStore.migrate(old)
        XCTAssertEqual(migrated.version, RoutingRuleDocument.currentVersion)
        XCTAssertEqual(migrated.rules.count, 1, "migration must not drop rules")
    }

    func testConcurrentUpdatesDoNotLoseRules() {
        let expectation = expectation(description: "writes finished")
        expectation.expectedFulfillmentCount = 50
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            self.store.update(AppGroupKey("app.\(index)")) { $0.volume = 0.5 }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(store.allRules.count, 50)
    }
}

final class FileRuleStorageTests: XCTestCase {

    func testWritesAndReadsBackFromDisk() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wave-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storage = FileRuleStorage(fileURL: directory.appendingPathComponent("rules.json"))
        XCTAssertNil(try storage.read(), "a missing file is empty, not an error")

        let payload = Data("{\"version\":1,\"rules\":[]}".utf8)
        try storage.write(payload)
        XCTAssertEqual(try storage.read(), payload)
    }
}
