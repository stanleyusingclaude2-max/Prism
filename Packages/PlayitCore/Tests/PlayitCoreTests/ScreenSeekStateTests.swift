import XCTest
@testable import PlayitCore

final class ScreenSeekStateTests: XCTestCase {
    func testShortClipMapsBothDirectionsRelativeToOriginalTime() throws {
        let state = try XCTUnwrap(ScreenSeekState(startTime: 10, duration: 20, viewportWidth: 400))
        XCTAssertEqual(try XCTUnwrap(state.target(horizontalTranslation: 100)), 15, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(state.target(horizontalTranslation: -100)), 5, accuracy: 0.0001)
    }

    func testReversingTheFingerDoesNotAccumulatePreviousTargets() throws {
        let state = try XCTUnwrap(ScreenSeekState(startTime: 10, duration: 20, viewportWidth: 400))
        _ = state.target(horizontalTranslation: 100)
        _ = state.target(horizontalTranslation: 60)
        XCTAssertEqual(state.target(horizontalTranslation: 0), 10)
        XCTAssertEqual(state.target(horizontalTranslation: -40), 8)
    }

    func testDraggingNearEitherEndClampsToTheAvailableVideo() throws {
        let nearStart = try XCTUnwrap(ScreenSeekState(startTime: 1, duration: 15, viewportWidth: 375))
        let nearEnd = try XCTUnwrap(ScreenSeekState(startTime: 14, duration: 15, viewportWidth: 375))
        XCTAssertEqual(nearStart.target(horizontalTranslation: -200), 0)
        XCTAssertEqual(nearEnd.target(horizontalTranslation: 200), 15)
    }

    func testLongClipsKeepAWholeWidthDragAtSixtySeconds() throws {
        let state = try XCTUnwrap(ScreenSeekState(startTime: 150, duration: 300, viewportWidth: 800))
        XCTAssertEqual(state.secondsPerViewport, 60)
        XCTAssertEqual(state.target(horizontalTranslation: 800), 210)
        XCTAssertEqual(state.target(horizontalTranslation: -400), 120)
    }

    func testLandscapeUsesItsOwnCapturedViewportWidth() throws {
        let portrait = try XCTUnwrap(ScreenSeekState(startTime: 4, duration: 16, viewportWidth: 400))
        let landscape = try XCTUnwrap(ScreenSeekState(startTime: 4, duration: 16, viewportWidth: 800))
        XCTAssertEqual(portrait.target(horizontalTranslation: 100), 8)
        XCTAssertEqual(landscape.target(horizontalTranslation: 100), 6)
    }

    func testVeryShortClipRetainsFractionalSecondPrecision() throws {
        let state = try XCTUnwrap(ScreenSeekState(startTime: 0.2, duration: 0.8, viewportWidth: 400))
        XCTAssertEqual(try XCTUnwrap(state.target(horizontalTranslation: 25)), 0.25, accuracy: 0.000001)
    }

    func testInvalidMetadataAndTouchPositionsAreRejected() throws {
        for duration in [0, -1, Double.nan, .infinity] {
            XCTAssertNil(ScreenSeekState(startTime: 1, duration: duration, viewportWidth: 400))
        }
        for width in [0, -1, Double.nan, .infinity] {
            XCTAssertNil(ScreenSeekState(startTime: 1, duration: 10, viewportWidth: width))
        }
        XCTAssertNil(ScreenSeekState(startTime: .nan, duration: 10, viewportWidth: 400))
        let state = try XCTUnwrap(ScreenSeekState(startTime: 1, duration: 10, viewportWidth: 400))
        XCTAssertNil(state.target(horizontalTranslation: .nan))
        XCTAssertNil(state.target(horizontalTranslation: .infinity))
    }

    func testExtremeFiniteTranslationStillClampsWithoutOverflow() throws {
        let state = try XCTUnwrap(ScreenSeekState(startTime: 1, duration: 10, viewportWidth: 0.5))
        XCTAssertEqual(state.target(horizontalTranslation: .greatestFiniteMagnitude), 10)
        XCTAssertEqual(state.target(horizontalTranslation: -.greatestFiniteMagnitude), 0)
        XCTAssertEqual(ScreenSeekState(startTime: -2, duration: 10, viewportWidth: 400)?.startTime, 0)
        XCTAssertEqual(ScreenSeekState(startTime: 20, duration: 10, viewportWidth: 400)?.startTime, 10)
    }

    func testDirectionThresholdAcceptsSmallAndSlightlyDiagonalHorizontalMoves() {
        XCTAssertTrue(ScreenSeekState.shouldBegin(horizontal: 12, vertical: 2))
        XCTAssertTrue(ScreenSeekState.shouldBegin(horizontal: -12, vertical: 2))
        XCTAssertTrue(ScreenSeekState.shouldBegin(horizontal: 6, vertical: 1))
        XCTAssertTrue(ScreenSeekState.shouldBegin(horizontal: 12, vertical: 12))
        XCTAssertFalse(ScreenSeekState.shouldBegin(horizontal: 3, vertical: 1))
        XCTAssertFalse(ScreenSeekState.shouldBegin(horizontal: 8, vertical: 16))
        XCTAssertFalse(ScreenSeekState.shouldBegin(horizontal: .nan, vertical: 0))
        XCTAssertFalse(ScreenSeekState.shouldBegin(horizontal: 10, vertical: .infinity))
    }

    func testSlightlyVerticalStartCanBecomeHorizontalWithoutLosingTheTouch() {
        var direction = ScreenSeekDirectionLock()
        XCTAssertEqual(direction.update(horizontal: 2, vertical: 4), .pending)
        XCTAssertEqual(direction.update(horizontal: 5, vertical: 7), .pending)
        XCTAssertEqual(direction.update(horizontal: 10, vertical: 8), .horizontal)
    }

    func testSlowSmallMovementsEventuallyRecognizeInEitherDirection() {
        for sign in [-1.0, 1.0] {
            var direction = ScreenSeekDirectionLock()
            for x in [0.5, 1, 2, 3, 4, 5] {
                XCTAssertEqual(direction.update(horizontal: sign * x, vertical: 1), .pending)
            }
            XCTAssertEqual(direction.update(horizontal: sign * 6, vertical: 1), .horizontal)
        }
    }

    func testHorizontalLockSurvivesReversingThroughTheOriginAndVerticalDrift() {
        var direction = ScreenSeekDirectionLock()
        XCTAssertEqual(direction.update(horizontal: 8, vertical: 2), .horizontal)
        XCTAssertEqual(direction.update(horizontal: 0, vertical: 15), .horizontal)
        XCTAssertEqual(direction.update(horizontal: -20, vertical: 30), .horizontal)
    }

    func testClearlyVerticalGestureIsRejectedAndDoesNotBecomeASeekLater() {
        var direction = ScreenSeekDirectionLock()
        XCTAssertEqual(direction.update(horizontal: 3, vertical: 8), .pending)
        XCTAssertEqual(direction.update(horizontal: 3, vertical: 12), .vertical)
        XCTAssertEqual(direction.update(horizontal: 40, vertical: 13), .vertical)
    }

    func testTapJitterNeverLocksASeekDirection() {
        var direction = ScreenSeekDirectionLock()
        for (x, y) in [(1.0, 1.0), (-3, 2), (2, -4), (0, 0)] {
            XCTAssertEqual(direction.update(horizontal: x, vertical: y), .pending)
        }
    }

    func testInvalidDirectionSamplesDoNotPoisonLaterValidMovement() {
        var direction = ScreenSeekDirectionLock()
        XCTAssertEqual(direction.update(horizontal: .nan, vertical: 0), .pending)
        XCTAssertEqual(direction.update(horizontal: 10, vertical: .infinity), .pending)
        XCTAssertEqual(direction.update(horizontal: -8, vertical: 2), .horizontal)
    }
}
