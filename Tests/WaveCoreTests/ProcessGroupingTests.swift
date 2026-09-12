import XCTest
@testable import WaveCore

final class ProcessGroupingTests: XCTestCase {

    // MARK: - Bundle identifier canonicalisation

    func testChromeHelpersFoldIntoChrome() {
        XCTAssertEqual(ProcessGrouping.canonicalise("com.google.Chrome.helper"), "com.google.Chrome")
        XCTAssertEqual(ProcessGrouping.canonicalise("com.google.Chrome.helper.renderer"), "com.google.Chrome")
        XCTAssertEqual(ProcessGrouping.canonicalise("com.google.Chrome.helper.gpu"), "com.google.Chrome")
    }

    func testElectronHelpersFoldIntoTheirApp() {
        XCTAssertEqual(ProcessGrouping.canonicalise("com.tinyspeck.slackmacgap.helper"), "com.tinyspeck.slackmacgap")
        XCTAssertEqual(ProcessGrouping.canonicalise("com.hnc.Discord.helper.renderer"), "com.hnc.Discord")
    }

    func testSafariWebKitProcessesFoldIntoSafari() {
        XCTAssertEqual(ProcessGrouping.canonicalise("com.apple.WebKit.GPU"), "com.apple.Safari")
        XCTAssertEqual(ProcessGrouping.canonicalise("com.apple.WebKit.WebContent"), "com.apple.Safari")
    }

    func testOrdinaryIdentifiersAreUntouched() {
        XCTAssertEqual(ProcessGrouping.canonicalise("com.spotify.client"), "com.spotify.client")
        XCTAssertEqual(ProcessGrouping.canonicalise("com.apple.Music"), "com.apple.Music")
    }

    /// A longer suffix must win, otherwise `.helper.renderer` would be trimmed
    /// to `com.google.Chrome.helper` and produce a second, phantom row.
    func testLongestSuffixWins() {
        XCTAssertEqual(ProcessGrouping.canonicalise("com.example.app.helper.renderer"), "com.example.app")
    }

    func testAnIdentifierThatIsOnlyASuffixIsNotEmptied() {
        XCTAssertEqual(ProcessGrouping.canonicalise(".helper"), ".helper")
    }

    // MARK: - Bundle path walking

    func testFindsOutermostAppWrapperForNestedElectronHelper() {
        let path = "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"
        XCTAssertEqual(ProcessGrouping.outermostAppBundlePath(forExecutablePath: path), "/Applications/Slack.app")
    }

    func testFindsPlainAppWrapper() {
        let path = "/Applications/Spotify.app/Contents/MacOS/Spotify"
        XCTAssertEqual(ProcessGrouping.outermostAppBundlePath(forExecutablePath: path), "/Applications/Spotify.app")
    }

    func testReturnsNilForExecutablesOutsideABundle() {
        XCTAssertNil(ProcessGrouping.outermostAppBundlePath(forExecutablePath: "/usr/sbin/coreaudiod"))
    }

    // MARK: - Group keys

    func testEnclosingBundleWinsOverTheHelpersOwnIdentifier() {
        // This is the case that matters: Chrome's renderer reports its own
        // helper identifier, but macOS knows the process lives inside Chrome.
        let facts = AudioProcessFacts(pid: 42,
                                      bundleID: "com.google.Chrome.helper",
                                      executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                                      enclosingBundleID: "com.google.Chrome")
        XCTAssertEqual(ProcessGrouping.groupKey(for: facts), AppGroupKey("com.google.Chrome"))
    }

    func testFallsBackToTheHelperIdentifierWhenNoBundleIsKnown() {
        let facts = AudioProcessFacts(pid: 42, bundleID: "com.google.Chrome.helper")
        XCTAssertEqual(ProcessGrouping.groupKey(for: facts), AppGroupKey("com.google.Chrome"))
    }

    func testCoreaudiodBecomesSystemSounds() {
        let facts = AudioProcessFacts(pid: 91, bundleID: nil, executablePath: "/usr/sbin/coreaudiod")
        XCTAssertEqual(ProcessGrouping.groupKey(for: facts), .systemSounds)
        XCTAssertTrue(ProcessGrouping.groupKey(for: facts).isSystemSounds)
    }

    func testExecutablePathIsTheLastResortBeforePID() {
        let facts = AudioProcessFacts(pid: 7, bundleID: nil, executablePath: "/usr/local/bin/mpv")
        XCTAssertEqual(ProcessGrouping.groupKey(for: facts), AppGroupKey.executable("/usr/local/bin/mpv"))
    }

    func testPIDIsUsedOnlyWhenNothingElseIsKnown() {
        let facts = AudioProcessFacts(pid: 7)
        XCTAssertEqual(ProcessGrouping.groupKey(for: facts), AppGroupKey("pid:7"))
    }

    // MARK: - Grouping

    func testFourChromeRenderersBecomeOneRow() {
        let renderers = (1...4).map { index in
            AudioProcessFacts(pid: Int32(100 + index),
                              bundleID: "com.google.Chrome.helper",
                              enclosingBundleID: "com.google.Chrome",
                              isProducingOutput: index == 2)
        }
        let grouped = ProcessGrouping.group(renderers)

        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].key, AppGroupKey("com.google.Chrome"))
        XCTAssertEqual(grouped[0].members.count, 4,
                       "all four helpers must be tappable as one unit")
    }

    func testDistinctApplicationsStaySeparate() {
        let processes = [
            AudioProcessFacts(pid: 1, bundleID: "com.spotify.client"),
            AudioProcessFacts(pid: 2, bundleID: "com.google.Chrome.helper", enclosingBundleID: "com.google.Chrome"),
            AudioProcessFacts(pid: 3, bundleID: "us.zoom.xos"),
        ]
        let grouped = ProcessGrouping.group(processes)
        XCTAssertEqual(grouped.count, 3)
        XCTAssertEqual(Set(grouped.map(\.key.rawValue)),
                       ["com.spotify.client", "com.google.Chrome", "us.zoom.xos"])
    }

    func testGroupingPreservesDiscoveryOrder() {
        let processes = [
            AudioProcessFacts(pid: 1, bundleID: "com.z.app"),
            AudioProcessFacts(pid: 2, bundleID: "com.a.app"),
        ]
        XCTAssertEqual(ProcessGrouping.group(processes).map(\.key.rawValue),
                       ["com.z.app", "com.a.app"],
                       "grouping must not reshuffle rows underneath the user")
    }

    func testEmptyInputProducesNoGroups() {
        XCTAssertTrue(ProcessGrouping.group([]).isEmpty)
    }
}
