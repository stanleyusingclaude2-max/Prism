import XCTest
@testable import PlayitCore

final class PlaybackChromeStateTests: XCTestCase {
    private let playing = PlaybackChromeState.Context(isReady: true, isPlaying: true)

    func testLoadingStartsVisibleAndArmsOnlyWhenPlaybackIsReady() {
        var state = PlaybackChromeState()
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
        state.update(.init(isPlaying: true), now: 100)
        state.advance(now: 500)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)

        state.update(playing, now: 501)
        XCTAssertEqual(state.deadline, 504)
        state.advance(now: 503.999)
        XCTAssertTrue(state.isVisible)
        state.advance(now: 504)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.deadline)
    }

    func testFrequentPlaybackPublicationsDoNotPostponeAutoHide() {
        var state = PlaybackChromeState()
        state.update(playing, now: 10)
        for time in stride(from: 10.1, through: 12.9, by: 0.1) {
            state.update(playing, now: time)
        }
        XCTAssertEqual(state.deadline, 13)
        state.advance(now: 13)
        XCTAssertFalse(state.isVisible)
        state.update(playing, now: 14)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.deadline)
    }

    func testInteractionResetsCurrentDeadlineAndAnOldTimerCannotHideIt() {
        var state = PlaybackChromeState()
        state.update(playing, now: 10)
        let oldDeadline = state.deadline!
        state.interact(now: 12.5)
        XCTAssertEqual(state.deadline, 15.5)
        state.advance(now: oldDeadline)
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.deadline, 15.5)
        state.advance(now: 15.5)
        XCTAssertFalse(state.isVisible)
        state.advance(now: 100)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.deadline)
    }

    func testTapCanHideAndRevealOnlyDuringEligiblePlayback() {
        var state = PlaybackChromeState()
        state.update(playing, now: 0)
        state.tapVideo(now: 1)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.deadline)
        state.tapVideo(now: 2)
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.deadline, 5)
        state.advance(now: 3) // The canceled original timer.
        XCTAssertTrue(state.isVisible)
        state.advance(now: 5)
        XCTAssertFalse(state.isVisible)
    }

    func testPausingAndEndOfPlaybackRevealControlsAndCancelTimer() {
        var state = PlaybackChromeState()
        state.update(playing, now: 0)
        state.advance(now: 3)
        state.update(.init(isReady: true, isPlaying: false), now: 10)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
        state.advance(now: 100)
        XCTAssertTrue(state.isVisible)
        state.update(playing, now: 101)
        XCTAssertEqual(state.deadline, 104)
    }

    func testPausedVideoCanBeManuallyClearedWithoutAutoHideOrPublishReopening() {
        var state = PlaybackChromeState()
        let paused = PlaybackChromeState.Context(isReady: true)
        state.update(paused, now: 0)
        state.tapVideo(now: 1)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.deadline)
        for time in [2.0, 3.0, 10.0, 100.0] {
            state.update(paused, now: time)
            state.advance(now: time)
            XCTAssertFalse(state.isVisible)
            XCTAssertNil(state.deadline)
        }
        state.tapVideo(now: 101)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
        state.advance(now: 1000)
        XCTAssertTrue(state.isVisible)
    }

    func testPausedControlInteractionRevealsWithoutArmingADeadline() {
        var state = PlaybackChromeState()
        state.update(.init(isReady: true), now: 0)
        state.tapVideo(now: 1)
        state.interact(now: 2)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
        state.advance(now: 100)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
    }

    func testHiddenPausedControlsRemainHiddenAfterTemporaryFastPlaybackRelease() {
        var state = PlaybackChromeState()
        let paused = PlaybackChromeState.Context(isReady: true)
        state.update(paused, now: 0)
        state.tapVideo(now: 1)
        state.update(.init(isReady: true, isTemporaryFastPlayback: true), now: 2)
        state.update(.init(isReady: true, isPlaying: true, isTemporaryFastPlayback: true), now: 3)
        state.advance(now: 100)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.deadline)
        state.update(paused, now: 101)
        state.update(paused, now: 102)
        state.advance(now: 200)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.deadline)
        state.tapVideo(now: 201)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
    }

    func testEnteringPauseFromPlaybackLoadingOrLockRevealsControls() {
        let startingContexts: [PlaybackChromeState.Context] = [
            playing,
            .init(isPlaying: true),
            .init(isReady: true, isPlaying: true, isLocked: true)
        ]
        for starting in startingContexts {
            var state = PlaybackChromeState()
            state.update(starting, now: 0)
            state.advance(now: 3)
            state.update(.init(isReady: true), now: 4)
            XCTAssertTrue(state.isVisible)
            XCTAssertNil(state.deadline)
        }
    }

    func testPausedManualHideCannotSuppressLoadingScrubOptionsOrAccessibility() {
        let holds: [PlaybackChromeState.Context] = [
            .init(),
            .init(isReady: true, isScrubbing: true),
            .init(isReady: true, isPresentingOptions: true),
            .init(isReady: true, hasError: true),
            .init(isReady: true, isVoiceOverRunning: true),
            .init(isReady: true, isSceneActive: false)
        ]
        for context in holds {
            var state = PlaybackChromeState()
            state.update(.init(isReady: true), now: 0)
            state.tapVideo(now: 1)
            XCTAssertFalse(state.isVisible)
            state.update(context, now: 2)
            state.tapVideo(now: 3)
            state.advance(now: 100)
            XCTAssertTrue(state.isVisible)
            XCTAssertNil(state.deadline)
            state.update(.init(isReady: true), now: 101)
            XCTAssertTrue(state.isVisible)
            XCTAssertNil(state.deadline)
        }
    }

    func testScrubHoldsControlsThroughDecodeCommitAndThenStartsFreshDelay() {
        var state = PlaybackChromeState()
        state.update(playing, now: 0)
        state.advance(now: 3)
        state.update(.init(isReady: true, isPlaying: true, isScrubbing: true), now: 4)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
        state.tapVideo(now: 5)
        state.advance(now: 50)
        XCTAssertTrue(state.isVisible)
        state.update(playing, now: 51)
        XCTAssertEqual(state.deadline, 54)
        state.advance(now: 53.999)
        XCTAssertTrue(state.isVisible)
        state.advance(now: 54)
        XCTAssertFalse(state.isVisible)
    }

    func testOptionsErrorsVoiceOverAndInactiveSceneForceVisible() {
        let holds: [PlaybackChromeState.Context] = [
            .init(isReady: true, isPlaying: true, isPresentingOptions: true),
            .init(isReady: true, isPlaying: true, hasError: true),
            .init(isReady: true, isPlaying: true, isVoiceOverRunning: true),
            .init(isReady: true, isPlaying: true, isSceneActive: false)
        ]
        for context in holds {
            var state = PlaybackChromeState()
            state.update(playing, now: 0)
            state.advance(now: 3)
            state.update(context, now: 4)
            state.tapVideo(now: 5)
            state.interact(now: 6)
            state.advance(now: 100)
            XCTAssertTrue(state.isVisible)
            XCTAssertNil(state.deadline)
            state.update(playing, now: 101)
            XCTAssertEqual(state.deadline, 104)
        }
    }

    func testOldTimerDuringHoldCannotHideControlsOrReuseOldDeadline() {
        var state = PlaybackChromeState()
        state.update(playing, now: 10)
        state.update(.init(isReady: true, isPlaying: true, isPresentingOptions: true), now: 12)
        state.advance(now: 13)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
        state.update(playing, now: 20)
        state.advance(now: 20.5)
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.deadline, 23)
    }

    func testLockOverridesAllReasonsForShowingAndRejectsTaps() {
        var state = PlaybackChromeState()
        state.update(.init(
            isPlaying: false,
            isScrubbing: true,
            isLocked: true,
            isTemporaryFastPlayback: true,
            isSceneActive: false,
            isVoiceOverRunning: true,
            isPresentingOptions: true,
            hasError: true
        ), now: 10)
        state.interact(now: 11)
        state.tapVideo(now: 12)
        state.advance(now: 100)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.deadline)

        // An unlocked but paused snapshot must immediately reveal controls.
        state.update(.init(isReady: true), now: 101)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
    }

    func testExplicitUnlockInteractionRevealsAndArmsAFullInterval() {
        var state = PlaybackChromeState()
        state.update(playing, now: 0)
        state.update(.init(isReady: true, isPlaying: true, isLocked: true), now: 1)
        state.update(playing, now: 2)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.deadline)
        state.interact(now: 2)
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.deadline, 5)
        state.advance(now: 3)
        XCTAssertTrue(state.isVisible)
    }

    func testTemporaryFastPlaybackPreservesHiddenControlsWithoutNewTimer() {
        var state = PlaybackChromeState()
        state.update(playing, now: 0)
        state.advance(now: 3)
        state.update(.init(isReady: true, isPlaying: true, isTemporaryFastPlayback: true), now: 4)
        state.interact(now: 5)
        state.tapVideo(now: 6)
        state.advance(now: 100)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.deadline)
        state.update(playing, now: 101)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.deadline)
    }

    func testTemporaryFastPlaybackPreservesVisibleControlsAndCancelsCountdown() {
        var state = PlaybackChromeState()
        state.update(playing, now: 0)
        state.update(.init(isReady: true, isPlaying: true, isTemporaryFastPlayback: true), now: 2.9)
        state.advance(now: 3)
        state.advance(now: 100)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
        state.update(playing, now: 101)
        XCTAssertEqual(state.deadline, 104)
    }

    func testTemporaryPlaybackStartedFromPauseDoesNotFlashOrArmTimer() {
        var state = PlaybackChromeState()
        state.update(.init(isReady: true), now: 0)
        // The fast-play press can arrive before the decoder publishes playing.
        state.update(.init(isReady: true, isTemporaryFastPlayback: true), now: 1)
        state.update(.init(isReady: true, isPlaying: true, isTemporaryFastPlayback: true), now: 2)
        state.advance(now: 100)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
        state.update(.init(isReady: true), now: 101)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
    }

    func testForcedVisibleConditionWinsOverTemporaryPreservation() {
        var state = PlaybackChromeState()
        state.update(playing, now: 0)
        state.advance(now: 3)
        state.update(.init(isReady: true, isPlaying: true, isTemporaryFastPlayback: true), now: 4)
        state.update(.init(
            isReady: true, isPlaying: true, isTemporaryFastPlayback: true,
            isVoiceOverRunning: true
        ), now: 5)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
        state.update(.init(isReady: true, isPlaying: true, isTemporaryFastPlayback: true), now: 6)
        state.advance(now: 100)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
        state.update(playing, now: 101)
        XCTAssertEqual(state.deadline, 104)
    }

    func testNonFiniteClockCannotCreateInvalidDeadlineOrHideControls() {
        var state = PlaybackChromeState()
        state.update(playing, now: .nan)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
        state.advance(now: .infinity)
        state.advance(now: -.infinity)
        XCTAssertTrue(state.isVisible)
        state.advance(now: 10)
        XCTAssertEqual(state.deadline, 13)
        state.interact(now: .nan)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.deadline)
        state.advance(now: 11)
        XCTAssertEqual(state.deadline, 14)
    }

    func testOlderClockSamplesCannotShortenAFreshInteractionInterval() {
        var state = PlaybackChromeState()
        state.update(playing, now: 10)
        state.interact(now: 12)
        state.interact(now: 11)
        XCTAssertEqual(state.deadline, 15)
        state.advance(now: 13)
        XCTAssertTrue(state.isVisible)
        state.advance(now: 15)
        XCTAssertFalse(state.isVisible)
    }

    func testDelayConfigurationAndOverflowRemainFinite() {
        for delay in [-1.0, .nan, .infinity] {
            var state = PlaybackChromeState(autoHideDelay: delay)
            state.update(playing, now: 10)
            XCTAssertEqual(state.deadline, 13)
        }
        var immediate = PlaybackChromeState(autoHideDelay: 0)
        immediate.update(playing, now: 10)
        XCTAssertTrue(immediate.isVisible)
        immediate.advance(now: 10)
        XCTAssertFalse(immediate.isVisible)

        var overflow = PlaybackChromeState(autoHideDelay: .greatestFiniteMagnitude)
        overflow.update(playing, now: .greatestFiniteMagnitude)
        XCTAssertTrue(overflow.isVisible)
        XCTAssertNil(overflow.deadline)
    }
}
