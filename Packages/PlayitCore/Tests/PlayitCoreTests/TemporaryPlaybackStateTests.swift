import XCTest
@testable import PlayitCore

final class TemporaryPlaybackStateTests: XCTestCase {
    func testPlayingGestureRestoresCustomRateAndPlayback() {
        var state = TemporaryPlaybackState()
        XCTAssertEqual(state.begin(originalRate: 1.5, wasPlaying: true), .init(rate: 2, isPlaying: true))
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.end(), .init(rate: 1.5, isPlaying: true))
        XCTAssertFalse(state.isActive)
    }

    func testPausedGestureTemporarilyPlaysAndRestoresPause() {
        var state = TemporaryPlaybackState()
        XCTAssertEqual(state.begin(originalRate: 0.75, wasPlaying: false), .init(rate: 2, isPlaying: true))
        XCTAssertEqual(state.end(), .init(rate: 0.75, isPlaying: false))
    }

    func testRepeatedBeginDoesNotOverwriteOriginalState() {
        var state = TemporaryPlaybackState()
        _ = state.begin(originalRate: 1.25, wasPlaying: false)
        XCTAssertNil(state.begin(originalRate: 2, wasPlaying: true))
        XCTAssertEqual(state.end(), .init(rate: 1.25, isPlaying: false))
    }

    func testBackgroundCancellationRestoresRateWithoutResuming() {
        var state = TemporaryPlaybackState()
        _ = state.begin(originalRate: 1.5, wasPlaying: true)
        XCTAssertEqual(state.cancel(), .init(rate: 1.5, isPlaying: false))
        XCTAssertFalse(state.isActive)
    }

    func testLateReleaseAfterCancellationCannotResume() {
        var state = TemporaryPlaybackState()
        _ = state.begin(originalRate: 1, wasPlaying: true)
        _ = state.cancel()
        XCTAssertNil(state.end())
        XCTAssertNil(state.cancel())
    }

    func testReachingEndDoesNotRestartVideoOnRelease() {
        var state = TemporaryPlaybackState()
        _ = state.begin(originalRate: 0.5, wasPlaying: true)
        XCTAssertEqual(state.end(reachedEnd: true), .init(rate: 0.5, isPlaying: false))
    }

    func testSubsequentGestureUsesItsOwnPlaybackState() {
        var state = TemporaryPlaybackState()
        _ = state.begin(originalRate: 1.5, wasPlaying: true)
        _ = state.end()
        _ = state.begin(originalRate: 0.25, wasPlaying: false)
        XCTAssertEqual(state.end(), .init(rate: 0.25, isPlaying: false))
    }

    func testInvalidRatesDoNotCreateSession() {
        for rate in [Float.nan, .infinity, 0, -1] {
            var state = TemporaryPlaybackState()
            XCTAssertNil(state.begin(originalRate: rate, wasPlaying: true))
            XCTAssertFalse(state.isActive)
            XCTAssertNil(state.end())
        }
    }
}
