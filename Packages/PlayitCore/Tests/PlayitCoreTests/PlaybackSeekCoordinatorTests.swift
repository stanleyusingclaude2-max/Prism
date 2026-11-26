import XCTest
@testable import PlayitCore

final class PlaybackSeekCoordinatorTests: XCTestCase {
    private typealias Seek = PlaybackSeekCoordinator.Seek
    private let session = UUID()
    private var nextID: UInt64 = 0

    private func seek(_ target: Double, exact: Bool, commit: Bool = false, resume: Bool = false,
                      session: UUID? = nil) -> Seek {
        nextID += 1
        return Seek(id: nextID, target: target, session: session ?? self.session, exact: exact,
                    commit: commit, resume: resume, pauseRevision: 0)
    }

    /// mpv's events for a seek it accepted and finished: reply, seek, restart.
    private func complete(_ coordinator: inout PlaybackSeekCoordinator, _ sent: Seek,
                          at now: Double) -> (finished: Seek?, next: PlaybackSeekCoordinator.Action?) {
        XCTAssertEqual(coordinator.replied(id: sent.id), .running)
        coordinator.seekStarted()
        return coordinator.playbackRestarted(now: now)
    }

    func testFastDragKeepsOneSeekRunningAndOnlyTheNewestWaiting() {
        var coordinator = PlaybackSeekCoordinator()
        let first = seek(10, exact: false)
        XCTAssertEqual(coordinator.submit(first, now: 0), .send(first))
        XCTAssertNil(coordinator.submit(seek(20, exact: false), now: 0.01))
        let newest = seek(30, exact: false)
        XCTAssertNil(coordinator.submit(newest, now: 0.02))
        XCTAssertEqual(coordinator.waiting, newest)

        let result = complete(&coordinator, first, at: 0.05)
        XCTAssertEqual(result.finished, first)
        XCTAssertEqual(result.next, .send(newest))
        XCTAssertNil(coordinator.waiting)
    }

    func testRestartBeforeTheRunningCommandWasAcceptedBelongsToAnOlderSeek() {
        var coordinator = PlaybackSeekCoordinator()
        let sent = seek(10, exact: false)
        _ = coordinator.submit(sent, now: 0)
        // Events of whatever mpv did before this command was queued.
        coordinator.seekStarted()
        XCTAssertNil(coordinator.playbackRestarted(now: 0.01).finished)
        XCTAssertEqual(coordinator.replied(id: sent.id), .running)
        // A restart without this seek's own seek event is still not its own.
        XCTAssertNil(coordinator.playbackRestarted(now: 0.02).finished)
        coordinator.seekStarted()
        XCTAssertEqual(coordinator.playbackRestarted(now: 0.03).finished, sent)
    }

    func testSlowExactPreviewIsReplacedAndItsLateEventsDoNotFinishTheNewSeek() {
        var coordinator = PlaybackSeekCoordinator()
        let exact = seek(100, exact: true)
        XCTAssertEqual(coordinator.submit(exact, now: 0), .send(exact))
        XCTAssertEqual(coordinator.replied(id: exact.id), .running)
        coordinator.seekStarted()

        // Still decoding after 0.3 s: the newer target is sent at once.
        let newer = seek(400, exact: false)
        XCTAssertEqual(coordinator.submit(newer, now: 0.3), .send(newer))
        XCTAssertEqual(coordinator.running, newer)
        XCTAssertTrue(coordinator.exactSeeksAreSlow, "A replaced decode of 0.3 s already proves the file slow.")

        // The old decode happened to finish before mpv picked up the new seek.
        XCTAssertNil(coordinator.playbackRestarted(now: 0.31).finished)
        XCTAssertEqual(coordinator.replied(id: newer.id), .running)
        XCTAssertNil(coordinator.playbackRestarted(now: 0.32).finished)
        coordinator.seekStarted()
        XCTAssertEqual(coordinator.playbackRestarted(now: 0.36).finished, newer)
    }

    func testReplacedSeeksRepliesAreRecognised() {
        var coordinator = PlaybackSeekCoordinator()
        let exact = seek(100, exact: true)
        _ = coordinator.submit(exact, now: 0)
        _ = coordinator.submit(seek(400, exact: false), now: 0.5)
        XCTAssertEqual(coordinator.replied(id: exact.id), .replaced)
        XCTAssertEqual(coordinator.replied(id: exact.id), .other)
        XCTAssertEqual(coordinator.replied(id: 9_999), .other)

        let another = seek(200, exact: true)
        var second = PlaybackSeekCoordinator()
        _ = second.submit(another, now: 0)
        _ = second.submit(seek(300, exact: false), now: 0.5)
        XCTAssertTrue(second.isReplaced(id: another.id))
        XCTAssertFalse(second.isReplaced(id: another.id))
    }

    func testQuickExactPreviewsAndKeyframePreviewsAreNeverReplaced() {
        var coordinator = PlaybackSeekCoordinator()
        let exact = seek(1, exact: true)
        _ = coordinator.submit(exact, now: 0)
        XCTAssertNil(coordinator.submit(seek(1.1, exact: true), now: 0.05), "0.05 s is not yet slow.")
        XCTAssertEqual(coordinator.running, exact)

        var keyframes = PlaybackSeekCoordinator()
        let keyframe = seek(50, exact: false)
        _ = keyframes.submit(keyframe, now: 0)
        XCTAssertNil(keyframes.submit(seek(90, exact: false), now: 5))
        XCTAssertEqual(keyframes.running, keyframe)
    }

    func testACommitIsNeverReplacedByALaterPreview() {
        var coordinator = PlaybackSeekCoordinator()
        let commit = seek(100, exact: true, commit: true, resume: true)
        _ = coordinator.submit(commit, now: 0)
        let next = UUID()
        XCTAssertNil(coordinator.submit(seek(10, exact: false, session: next), now: 3))
        XCTAssertEqual(coordinator.running, commit)
    }

    func testCommitAtTheTargetBeingDecodedUpgradesThatSeek() {
        var coordinator = PlaybackSeekCoordinator()
        let refinement = seek(42, exact: true)
        _ = coordinator.submit(refinement, now: 0)
        _ = coordinator.submit(seek(43, exact: false), now: 0.01)

        XCTAssertNil(coordinator.submit(seek(42, exact: true, commit: true, resume: true), now: 0.4),
                     "Lifting the finger where the exact frame is decoding starts no second decode.")
        XCTAssertNil(coordinator.waiting)
        let result = complete(&coordinator, refinement, at: 0.9)
        XCTAssertEqual(result.finished?.id, refinement.id)
        XCTAssertEqual(result.finished?.commit, true)
        XCTAssertEqual(result.finished?.resume, true)
        XCTAssertNil(result.next)
    }

    func testCommitAtTheExactFrameOnScreenFinishesWithoutSeeking() {
        var coordinator = PlaybackSeekCoordinator()
        let refinement = seek(42, exact: true)
        _ = coordinator.submit(refinement, now: 0)
        _ = complete(&coordinator, refinement, at: 0.8)

        let commit = seek(42, exact: true, commit: true, resume: true)
        XCTAssertEqual(coordinator.submit(commit, now: 1.5), .finish(commit))
        XCTAssertNil(coordinator.running)
    }

    func testOnlyTheUntouchedExactFrameOfTheSameDragCountsAsOnScreen() {
        func refined() -> PlaybackSeekCoordinator {
            var coordinator = PlaybackSeekCoordinator()
            let refinement = seek(42, exact: true)
            _ = coordinator.submit(refinement, now: 0)
            _ = complete(&coordinator, refinement, at: 0.1)
            return coordinator
        }

        var moved = refined()
        moved.pictureMoved()
        XCTAssertEqual(moved.submit(seek(42, exact: true, commit: true), now: 1).map(isSend), true)

        var otherDrag = refined()
        XCTAssertEqual(otherDrag.submit(seek(42, exact: true, commit: true, session: UUID()), now: 1).map(isSend), true)

        var elsewhere = refined()
        XCTAssertEqual(elsewhere.submit(seek(42.5, exact: true, commit: true), now: 1).map(isSend), true)

        var keyframeSince = refined()
        let keyframe = seek(60, exact: false)
        _ = keyframeSince.submit(keyframe, now: 1)
        _ = complete(&keyframeSince, keyframe, at: 1.05)
        XCTAssertEqual(keyframeSince.submit(seek(42, exact: true, commit: true), now: 2).map(isSend), true)
    }

    func testFinishedSeekWithANewerOneWaitingIsSuperseded() {
        var coordinator = PlaybackSeekCoordinator()
        let commit = seek(10, exact: true, commit: true, resume: true)
        _ = coordinator.submit(commit, now: 0)
        let laterDrag = seek(20, exact: false, session: UUID())
        XCTAssertNil(coordinator.submit(laterDrag, now: 0.05))
        let result = complete(&coordinator, commit, at: 0.1)
        XCTAssertEqual(result.finished, commit)
        XCTAssertEqual(result.next, .send(laterDrag), "The engine sees a next seek and does not finish the commit.")
    }

    func testDroppingWaitingPreviewsKeepsAWaitingCommit() {
        var coordinator = PlaybackSeekCoordinator()
        _ = coordinator.submit(seek(10, exact: false), now: 0)
        _ = coordinator.submit(seek(90, exact: false), now: 0.01)
        coordinator.dropWaitingPreview()
        XCTAssertNil(coordinator.waiting)

        let commit = seek(91, exact: true, commit: true)
        _ = coordinator.submit(commit, now: 0.02)
        coordinator.dropWaitingPreview()
        XCTAssertEqual(coordinator.waiting, commit)
        coordinator.dropWaiting()
        XCTAssertNil(coordinator.waiting)
    }

    func testAbandoningAStalledSeekSendsTheWaitingOne() {
        var coordinator = PlaybackSeekCoordinator()
        let stalled = seek(10, exact: false)
        _ = coordinator.submit(stalled, now: 0)
        let waiting = seek(20, exact: false)
        _ = coordinator.submit(waiting, now: 0.1)
        XCTAssertEqual(coordinator.abandonRunning(now: 12), .send(waiting))
        coordinator.reset()
        XCTAssertNil(coordinator.running)
        XCTAssertNil(coordinator.waiting)
    }

    func testSlowFinishedExactSeeksSwitchTheFileToKeyframePreviews() {
        var coordinator = PlaybackSeekCoordinator()
        XCTAssertFalse(coordinator.exactSeeksAreSlow)
        let exact = seek(10, exact: true)
        _ = coordinator.submit(exact, now: 0)
        _ = complete(&coordinator, exact, at: 0.6)
        XCTAssertTrue(coordinator.exactSeeksAreSlow)

        // Keyframe seeks say nothing about exact decoding.
        let keyframe = seek(70, exact: false)
        _ = coordinator.submit(keyframe, now: 1)
        _ = complete(&coordinator, keyframe, at: 1.02)
        XCTAssertTrue(coordinator.exactSeeksAreSlow)
    }

    /// A drag across a long video, simulated with an exact decode of 0.8 s and
    /// keyframe seeks of 30 ms: the picture keeps following the finger.
    func testLongVideoDragNeverWaitsBehindAnExactDecode() {
        var coordinator = PlaybackSeekCoordinator()
        var clock = 0.0
        var sentAt: [UInt64: Double] = [:]
        var running: Seek?
        var shownAt: [Double] = []
        let exactCost = 0.8, keyframeCost = 0.03

        func perform(_ action: PlaybackSeekCoordinator.Action?) {
            if case .send(let sent) = action {
                running = sent
                sentAt[sent.id] = clock
                XCTAssertEqual(coordinator.replied(id: sent.id), .running)
            }
        }
        func advance(to time: Double) {
            while let current = running, let start = sentAt[current.id],
                  start + (current.exact ? exactCost : keyframeCost) <= time {
                clock = start + (current.exact ? exactCost : keyframeCost)
                coordinator.seekStarted()
                let result = coordinator.playbackRestarted(now: clock)
                if result.finished != nil { shownAt.append(clock) }
                running = nil
                perform(result.next)
            }
            clock = time
        }

        // First the file is not known to be slow: a resting finger refines exactly.
        perform(coordinator.submit(seek(0, exact: true), now: 0))
        advance(to: 1)
        XCTAssertTrue(coordinator.exactSeeksAreSlow)

        // Then: a refinement starts, and the finger moves on at 60 Hz for 2 s.
        perform(coordinator.submit(seek(120, exact: true), now: 1))
        // Measured from the moment the finger starts moving again.
        shownAt = [1.05]
        var target = 120.0
        for step in 1...120 {
            let time = 1.05 + Double(step) / 60
            advance(to: time)
            target += 20
            let preview = PlaybackSeekPolicy.preview(precise: true, exactSeeksAreSlow: coordinator.exactSeeksAreSlow,
                                                     target: target, renderedTime: target - 20)
            XCTAssertEqual(preview, .keyframe)
            perform(coordinator.submit(seek(target, exact: false), now: time))
        }
        advance(to: 3.2)
        let gaps = zip(shownAt.dropFirst(), shownAt).map { $0 - $1 }
        XCTAssertGreaterThan(shownAt.count, 40, "Frames keep arriving while the finger moves.")
        XCTAssertLessThan(gaps.max() ?? 1, 0.1, "No frame waits behind an exact decode.")
    }
}

private func isSend(_ action: PlaybackSeekCoordinator.Action) -> Bool {
    if case .send = action { return true }
    return false
}
