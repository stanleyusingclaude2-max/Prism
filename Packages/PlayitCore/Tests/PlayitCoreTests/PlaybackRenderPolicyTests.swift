import XCTest
@testable import PlayitCore

final class PlaybackRenderPolicyTests: XCTestCase {
    private let gib: UInt64 = 1_024 * 1_024 * 1_024

    func testModernPhoneGetsMoreSourceDetailWithinItsMemoryBudget() {
        XCTAssertEqual(PlaybackRenderPolicy.drawableSide(nativeWidth: 1290, nativeHeight: 2796,
                                                        physicalMemory: 6 * gib, conservingPower: false), 3584)
        XCTAssertEqual(PlaybackRenderPolicy.drawableSide(nativeWidth: 2796, nativeHeight: 1290,
                                                        physicalMemory: 6 * gib, conservingPower: false), 3584)
    }

    func testConstrainedDevicesAndPowerSavingKeepBoundedAllocation() {
        for memory in [2 * gib, 6 * gib] {
            XCTAssertEqual(PlaybackRenderPolicy.drawableSide(nativeWidth: 1290, nativeHeight: 2796,
                                                            physicalMemory: memory, conservingPower: true), 2048)
        }
        XCTAssertEqual(PlaybackRenderPolicy.drawableSide(nativeWidth: 1290, nativeHeight: 2796,
                                                        physicalMemory: 4 * gib, conservingPower: false), 3072)
        XCTAssertEqual(PlaybackRenderPolicy.drawableSide(nativeWidth: 1290, nativeHeight: 2796,
                                                        physicalMemory: 2 * gib, conservingPower: false), 2048)
    }

    func testVeryLargeScreensCannotExceedTheSessionCap() {
        XCTAssertEqual(PlaybackRenderPolicy.drawableSide(nativeWidth: 7680, nativeHeight: 4320,
                                                        physicalMemory: 16 * gib, conservingPower: false), 4096)
        XCTAssertEqual(PlaybackRenderPolicy.drawableSide(nativeWidth: 640, nativeHeight: 960,
                                                        physicalMemory: 6 * gib, conservingPower: false), 1536)
    }

    func testKnownSourceSizeAvoidsSupersamplingSmallerVideos() {
        // iPhone 15 Pro: 1179 × 2556 pixels, 8 GB.
        XCTAssertEqual(PlaybackRenderPolicy.drawableSide(nativeWidth: 1179, nativeHeight: 2556, physicalMemory: 8 * gib,
                                                        conservingPower: false, sourceLongSide: 1920), 2048)
        XCTAssertEqual(PlaybackRenderPolicy.drawableSide(nativeWidth: 1179, nativeHeight: 2556, physicalMemory: 8 * gib,
                                                        conservingPower: false, sourceLongSide: 1280), 2048)
        XCTAssertEqual(PlaybackRenderPolicy.drawableSide(nativeWidth: 1179, nativeHeight: 2556, physicalMemory: 8 * gib,
                                                        conservingPower: false, sourceLongSide: 2560), 2560)
        XCTAssertEqual(PlaybackRenderPolicy.drawableSide(nativeWidth: 1290, nativeHeight: 2796, physicalMemory: 8 * gib,
                                                        conservingPower: false, sourceLongSide: 1920), 2304)
    }

    func testLargeOrUnknownSourcesKeepTheScreenBasedTarget() {
        XCTAssertEqual(PlaybackRenderPolicy.drawableSide(nativeWidth: 1179, nativeHeight: 2556, physicalMemory: 8 * gib,
                                                        conservingPower: false, sourceLongSide: 3840), 3328)
        for invalid in [0.0, -1, .nan, .infinity] {
            XCTAssertEqual(PlaybackRenderPolicy.drawableSide(nativeWidth: 1179, nativeHeight: 2556, physicalMemory: 8 * gib,
                                                            conservingPower: false, sourceLongSide: invalid), 3328)
        }
        XCTAssertEqual(PlaybackRenderPolicy.drawableSide(nativeWidth: 640, nativeHeight: 960, physicalMemory: 6 * gib,
                                                        conservingPower: false, sourceLongSide: 640), 1536)
    }

    func testInvalidScreenDimensionsUseSafeBaseline() {
        for invalid in [0.0, -1, .nan, .infinity] {
            XCTAssertEqual(PlaybackRenderPolicy.drawableSide(nativeWidth: invalid, nativeHeight: 2000,
                                                            physicalMemory: 6 * gib, conservingPower: false), 2048)
        }
    }

    func testNaturalMetalExtentRemainsStableAtEveryChosenSize() throws {
        let geometry = try XCTUnwrap(VideoDisplayGeometry(width: 3840, height: 2160, rotationDegrees: 0))
        for side in [1536.0, 2048, 3072, 3584, 4096] {
            for viewport in [(393.0, 852.0), (852.0, 393.0)] {
                for zoom in [1.0, 2.0] {
                    let layout = try XCTUnwrap(VideoSurfaceLayout(viewportWidth: viewport.0, viewportHeight: viewport.1,
                                                                 geometry: geometry, zoomScale: zoom))
                    let scale = try XCTUnwrap(layout.contentsScale(forDrawableSide: side))
                    XCTAssertEqual(Int(layout.layerFrame.width * scale), Int(side))
                    XCTAssertEqual(Int(layout.layerFrame.height * scale), Int(side))
                }
            }
        }
    }

    func testFinalCommitAndPausedInspectionAlwaysUseExactSeeking() {
        XCTAssertTrue(PlaybackSeekPolicy.usesExactSeek(commit: true, precisePreview: false, target: 90, renderedTime: 1))
        XCTAssertTrue(PlaybackSeekPolicy.usesExactSeek(commit: false, precisePreview: true, target: 90, renderedTime: 1))
    }

    func testLargePlayingScrubsCanUseFastPreviewWhileSmallMovesStayPrecise() {
        XCTAssertFalse(PlaybackSeekPolicy.usesExactSeek(commit: false, precisePreview: false, target: 30, renderedTime: 1))
        XCTAssertFalse(PlaybackSeekPolicy.usesExactSeek(commit: false, precisePreview: false, target: 1, renderedTime: 30))
        XCTAssertTrue(PlaybackSeekPolicy.usesExactSeek(commit: false, precisePreview: false, target: 1.2, renderedTime: 1))
    }
}

final class PlaybackSeekPreviewTests: XCTestCase {
    func testFastFilesKeepTheirPreviewBehaviour() {
        XCTAssertEqual(PlaybackSeekPolicy.preview(precise: true, exactSeeksAreSlow: false, target: 90, renderedTime: 1), .exact)
        XCTAssertEqual(PlaybackSeekPolicy.preview(precise: false, exactSeeksAreSlow: false, target: 90, renderedTime: 1), .keyframe)
        XCTAssertEqual(PlaybackSeekPolicy.preview(precise: false, exactSeeksAreSlow: false, target: 1.2, renderedTime: 1), .exact)
    }

    func testSlowFilesPreviewKeyframesAndLetSmallMovesWaitForRest() {
        for precise in [true, false] {
            XCTAssertEqual(PlaybackSeekPolicy.preview(precise: precise, exactSeeksAreSlow: true, target: 90, renderedTime: 1), .keyframe)
            XCTAssertEqual(PlaybackSeekPolicy.preview(precise: precise, exactSeeksAreSlow: true, target: 1, renderedTime: 90), .keyframe)
            XCTAssertEqual(PlaybackSeekPolicy.preview(precise: precise, exactSeeksAreSlow: true, target: 1.2, renderedTime: 1), .waitForRest)
        }
        XCTAssertEqual(PlaybackSeekPolicy.preview(precise: false, exactSeeksAreSlow: true, target: .nan, renderedTime: 1), .exact)
    }

    func testOnlySlowExactPreviewsAreReplaced() {
        XCTAssertTrue(PlaybackSeekPolicy.replacesRunningSeek(runningIsExact: true, runningIsCommit: false, runningFor: 0.25, exactSeeksAreSlow: false))
        XCTAssertTrue(PlaybackSeekPolicy.replacesRunningSeek(runningIsExact: true, runningIsCommit: false, runningFor: 0.01, exactSeeksAreSlow: true))
        XCTAssertFalse(PlaybackSeekPolicy.replacesRunningSeek(runningIsExact: true, runningIsCommit: false, runningFor: 0.1, exactSeeksAreSlow: false))
        XCTAssertFalse(PlaybackSeekPolicy.replacesRunningSeek(runningIsExact: false, runningIsCommit: false, runningFor: 5, exactSeeksAreSlow: true))
        XCTAssertFalse(PlaybackSeekPolicy.replacesRunningSeek(runningIsExact: true, runningIsCommit: true, runningFor: 5, exactSeeksAreSlow: true))
    }

    func testExactSeekCostFollowsRecentDecodes() {
        var cost = ExactSeekCost()
        cost.record(seconds: 0.05, finished: true)
        XCTAssertFalse(cost.isSlow)
        cost.record(seconds: 0.1, finished: false)
        XCTAssertFalse(cost.isSlow, "A seek replaced quickly proves nothing.")
        cost.record(seconds: 0.9, finished: true)
        XCTAssertTrue(cost.isSlow)
        for _ in 0..<4 { cost.record(seconds: 0.04, finished: true) }
        XCTAssertFalse(cost.isSlow, "A cold first decode wears off.")
        cost.record(seconds: .nan, finished: true)
        XCTAssertFalse(cost.isSlow)
    }
}
