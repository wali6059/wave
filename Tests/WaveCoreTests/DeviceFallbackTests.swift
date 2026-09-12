import XCTest
@testable import WaveCore

final class DeviceFallbackTests: XCTestCase {

    private let builtIn = OutputDeviceSnapshot(uid: "builtin",
                                               name: "MacBook Pro Speakers",
                                               outputChannelCount: 2,
                                               transport: .builtIn,
                                               isSystemDefault: true)
    private let airPods = OutputDeviceSnapshot(uid: "airpods",
                                               name: "AirPods Pro",
                                               outputChannelCount: 2,
                                               transport: .bluetooth)
    private let studio = OutputDeviceSnapshot(uid: "studio",
                                              name: "Studio Monitors",
                                              outputChannelCount: 2,
                                              transport: .usb)

    private func rule(uid: String?, name: String? = nil) -> RoutingRule {
        RoutingRule(appKey: AppGroupKey("com.example.app"),
                    volume: 0.65,
                    outputDeviceUID: uid,
                    outputDeviceName: name)
    }

    func testExactMatchWhenTheSavedDeviceIsPresent() {
        let resolution = DeviceFallbackPolicy.resolve(rule: rule(uid: "studio"),
                                                      devices: [builtIn, airPods, studio],
                                                      systemDefaultUID: "builtin")
        XCTAssertEqual(resolution, .exact(studio))
        XCTAssertFalse(resolution.isDegraded)
    }

    func testNilUIDFollowsTheSystemDefault() {
        let resolution = DeviceFallbackPolicy.resolve(rule: rule(uid: nil),
                                                      devices: [builtIn, airPods],
                                                      systemDefaultUID: "builtin")
        XCTAssertEqual(resolution, .systemDefault(builtIn))
        XCTAssertFalse(resolution.isDegraded)
    }

    /// The AirPods-yanked-out case. Audio must keep playing, and the UI must be
    /// told the rule is not being honoured.
    func testFallsBackToDefaultWhenTheSavedDeviceVanishes() {
        let resolution = DeviceFallbackPolicy.resolve(rule: rule(uid: "airpods", name: "AirPods Pro"),
                                                      devices: [builtIn],
                                                      systemDefaultUID: "builtin")
        XCTAssertEqual(resolution, .fellBack(to: builtIn, missingUID: "airpods", missingName: "AirPods Pro"))
        XCTAssertTrue(resolution.isDegraded)
        XCTAssertEqual(resolution.device, builtIn)
    }

    func testFallbackDoesNotRewriteTheSavedRule() {
        // The rule is a value type and the policy is pure, so there is nothing
        // that *could* rewrite it — this test pins that guarantee down, because
        // rewriting it would silently lose the user's real choice.
        let original = rule(uid: "airpods", name: "AirPods Pro")
        _ = DeviceFallbackPolicy.resolve(rule: original, devices: [builtIn], systemDefaultUID: "builtin")
        XCTAssertEqual(original.outputDeviceUID, "airpods")
    }

    func testDeadDevicesAreNotUsable() {
        let dead = OutputDeviceSnapshot(uid: "airpods", name: "AirPods Pro",
                                        outputChannelCount: 2, isAlive: false)
        let resolution = DeviceFallbackPolicy.resolve(rule: rule(uid: "airpods"),
                                                      devices: [builtIn, dead],
                                                      systemDefaultUID: "builtin")
        XCTAssertTrue(resolution.isDegraded)
        XCTAssertEqual(resolution.device, builtIn)
    }

    func testInputOnlyDevicesAreNotOfferedAsDestinations() {
        let microphone = OutputDeviceSnapshot(uid: "mic", name: "USB Microphone", outputChannelCount: 0)
        XCTAssertFalse(microphone.isUsableDestination)
        let resolution = DeviceFallbackPolicy.resolve(rule: rule(uid: "mic"),
                                                      devices: [builtIn, microphone],
                                                      systemDefaultUID: "builtin")
        XCTAssertTrue(resolution.isDegraded)
    }

    func testUnavailableWhenNothingIsPluggedIn() {
        let resolution = DeviceFallbackPolicy.resolve(rule: rule(uid: "studio", name: "Studio Monitors"),
                                                      devices: [],
                                                      systemDefaultUID: nil)
        XCTAssertEqual(resolution, .unavailable(missingUID: "studio", missingName: "Studio Monitors"))
        XCTAssertNil(resolution.device)
    }

    func testFollowSystemDefaultWithNoDevicesAtAll() {
        let resolution = DeviceFallbackPolicy.resolve(rule: rule(uid: nil),
                                                      devices: [],
                                                      systemDefaultUID: nil)
        XCTAssertEqual(resolution, .unavailable(missingUID: nil, missingName: nil))
    }

    func testFallsBackToIsSystemDefaultFlagWhenUIDIsUnknown() {
        let resolution = DeviceFallbackPolicy.resolve(rule: rule(uid: nil),
                                                      devices: [builtIn, airPods],
                                                      systemDefaultUID: nil)
        XCTAssertEqual(resolution, .systemDefault(builtIn))
    }

    // MARK: - Deciding what to restart

    func testOnlyAffectedRulesAreRerouted() {
        let rules = [
            RoutingRule(appKey: AppGroupKey("spotify"), outputDeviceUID: "studio"),
            RoutingRule(appKey: AppGroupKey("chrome"), outputDeviceUID: "builtin"),
            RoutingRule(appKey: AppGroupKey("zoom"), outputDeviceUID: "airpods"),
        ]
        // AirPods disconnect; nothing else moves.
        let affected = DeviceFallbackPolicy.rulesNeedingRerouting(
            rules: rules,
            previous: [builtIn, airPods, studio],
            current: [builtIn, studio],
            previousDefaultUID: "builtin",
            currentDefaultUID: "builtin")

        XCTAssertEqual(affected, [AppGroupKey("zoom")],
                       "unaffected apps must not be glitched by an unrelated hot-plug")
    }

    func testReconnectingADeviceReRoutesItBack() {
        let rules = [RoutingRule(appKey: AppGroupKey("zoom"), outputDeviceUID: "airpods")]
        let affected = DeviceFallbackPolicy.rulesNeedingRerouting(
            rules: rules,
            previous: [builtIn],
            current: [builtIn, airPods],
            previousDefaultUID: "builtin",
            currentDefaultUID: "builtin")
        XCTAssertEqual(affected, [AppGroupKey("zoom")])
    }

    func testChangingTheSystemDefaultMovesOnlyFollowers() {
        let rules = [
            RoutingRule(appKey: AppGroupKey("follower"), outputDeviceUID: nil),
            RoutingRule(appKey: AppGroupKey("pinned"), outputDeviceUID: "studio"),
        ]
        let affected = DeviceFallbackPolicy.rulesNeedingRerouting(
            rules: rules,
            previous: [builtIn, studio],
            current: [OutputDeviceSnapshot(uid: "builtin", name: "MacBook Pro Speakers", outputChannelCount: 2),
                      OutputDeviceSnapshot(uid: "studio", name: "Studio Monitors", outputChannelCount: 2, isSystemDefault: true)],
            previousDefaultUID: "builtin",
            currentDefaultUID: "studio")
        XCTAssertEqual(affected, [AppGroupKey("follower")])
    }

    func testNoChangeMeansNoRerouting() {
        let rules = [RoutingRule(appKey: AppGroupKey("spotify"), outputDeviceUID: "studio")]
        let affected = DeviceFallbackPolicy.rulesNeedingRerouting(
            rules: rules,
            previous: [builtIn, studio],
            current: [builtIn, studio],
            previousDefaultUID: "builtin",
            currentDefaultUID: "builtin")
        XCTAssertTrue(affected.isEmpty)
    }
}
