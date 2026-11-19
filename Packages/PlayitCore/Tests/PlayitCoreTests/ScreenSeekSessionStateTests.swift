import XCTest
@testable import PlayitCore

final class ScreenSeekSessionStateTests: XCTestCase {
    func testFingerUpAllowsAnotherDragBeforeDecoderCompletion() throws {
        var state = ScreenSeekSessionState()
        let first = try XCTUnwrap(state.begin(wasPlaying: true))
        XCTAssertEqual(state.endTouch(), first)
        let second = try XCTUnwrap(state.begin(wasPlaying: false))
        XCTAssertNotEqual(second, first)
        XCTAssertTrue(state.resumePlayback, "A pending decoder pause must not replace the original playing intent.")
    }

    func testOldCommitCannotFinishANewerActiveDrag() throws {
        var state = ScreenSeekSessionState()
        let first = try XCTUnwrap(state.begin(wasPlaying: true))
        state.endTouch()
        let second = try XCTUnwrap(state.begin(wasPlaying: false))
        XCTAssertFalse(state.complete(session: first))
        XCTAssertEqual(state.sessionID, second)
        XCTAssertTrue(state.isTouchActive)
        XCTAssertTrue(state.resumePlayback)
    }

    func testOnlyTheNewestLiftedDragCanFinishAndResetTheChain() throws {
        var state = ScreenSeekSessionState()
        let first = try XCTUnwrap(state.begin(wasPlaying: true))
        state.endTouch()
        let second = try XCTUnwrap(state.begin(wasPlaying: false))
        state.endTouch()
        XCTAssertFalse(state.complete(session: first))
        XCTAssertEqual(state.sessionID, second)
        XCTAssertTrue(state.complete(session: second))
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.resumePlayback)
        XCTAssertFalse(state.complete(session: second), "A duplicate commit is already consumed.")
    }

    func testConsecutivePausedDragsNeverAcquireAResumeIntent() throws {
        var state = ScreenSeekSessionState()
        _ = try XCTUnwrap(state.begin(wasPlaying: false))
        state.endTouch()
        _ = try XCTUnwrap(state.begin(wasPlaying: true))
        XCTAssertFalse(state.resumePlayback, "An intervening stale playing event cannot change the original pause intent.")
    }

    func testDuplicateBeginDuringTheSameTouchDoesNotReplaceTheSession() throws {
        var state = ScreenSeekSessionState()
        let first = try XCTUnwrap(state.begin(wasPlaying: true))
        XCTAssertNil(state.begin(wasPlaying: false))
        XCTAssertEqual(state.sessionID, first)
        XCTAssertTrue(state.resumePlayback)
    }

    func testCancellationInvalidatesPendingCommitAndNewDragStartsFresh() throws {
        var state = ScreenSeekSessionState()
        let first = try XCTUnwrap(state.begin(wasPlaying: true))
        state.endTouch()
        state.cancel()
        XCTAssertFalse(state.complete(session: first))
        let second = try XCTUnwrap(state.begin(wasPlaying: false))
        XCTAssertNotEqual(second, first)
        XCTAssertFalse(state.resumePlayback)
    }

    func testCommitCannotFinishBeforeTheFingerLifts() throws {
        var state = ScreenSeekSessionState()
        let session = try XCTUnwrap(state.begin(wasPlaying: false))
        XCTAssertFalse(state.complete(session: session))
        XCTAssertTrue(state.isTouchActive)
        XCTAssertEqual(state.endTouch(), session)
        XCTAssertTrue(state.complete(session: session))
    }

    func testSeveralPendingDragsKeepTheOriginalIntentUntilTheNewestCommit() throws {
        var state = ScreenSeekSessionState()
        let first = try XCTUnwrap(state.begin(wasPlaying: true))
        state.endTouch()
        let second = try XCTUnwrap(state.begin(wasPlaying: false))
        state.endTouch()
        let third = try XCTUnwrap(state.begin(wasPlaying: false))
        state.endTouch()
        XCTAssertFalse(state.complete(session: second))
        XCTAssertFalse(state.complete(session: first))
        XCTAssertEqual(state.sessionID, third)
        XCTAssertTrue(state.resumePlayback)
        XCTAssertTrue(state.complete(session: third))
        _ = try XCTUnwrap(state.begin(wasPlaying: false))
        XCTAssertFalse(state.resumePlayback, "A completed chain must not leak playback intent into later drags.")
    }
}
